const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;

// Cross-module imports (work for the exe build, not test_modules)
const auth_mod = @import("slack/auth.zig");
const api_mod = @import("slack/api.zig");
const socket_mod = @import("slack/socket.zig");
const cache_mod = @import("store/cache.zig");
const db_mod = @import("store/db.zig");
const root_mod = @import("tui/root.zig");
const keychain_mod = @import("platform/keychain.zig");
const types = @import("slack/types.zig");

const Auth = auth_mod.Auth;
const SlackClient = api_mod.SlackClient;
const SocketClient = socket_mod.SocketClient;
const EventQueue = socket_mod.EventQueue;
const Cache = cache_mod.Cache;
const CachedChannel = cache_mod.CachedChannel;
const CachedUser = cache_mod.CachedUser;
const CachedMessage = cache_mod.CachedMessage;
const Database = db_mod.Database;
const Root = root_mod.Root;
const Keychain = keychain_mod.Keychain;
const Sidebar = @import("tui/sidebar.zig").Sidebar;
const Messages = @import("tui/messages.zig").Messages;
const Modal = @import("tui/modal.zig").Modal;
const security = @import("security.zig");

const Event = vaxis.Event;
const Loop = vaxis.Loop;
const Mouse = vaxis.Mouse;

/// Application state management for zlack.
///
/// Owns all subsystems (auth, API client, socket, cache, DB, TUI)
/// and orchestrates the main event loop.
pub const App = struct {
    allocator: Allocator,
    auth: ?Auth,
    slack_client: ?SlackClient,
    socket_client: ?SocketClient,
    event_queue: EventQueue,
    cache: Cache,
    db: ?Database,
    tui_root: Root,
    vx: vaxis.Vaxis,
    tty_buf: [4096]u8,
    tty: ?vaxis.Tty,
    loop: ?Loop(Event),
    current_channel: ?[]const u8,
    reconfigure: bool,

    // Owned slices for TUI widget data (freed on update)
    sidebar_entries: ?[]Sidebar.ChannelEntry,
    message_entries: ?[]Messages.MessageEntry,
    thread_entries: ?[]Messages.MessageEntry,
    modal_items: ?[]Modal.ModalItem,

    // Double-click tracking
    last_click_time: i64 = 0,
    last_click_msg_idx: ?usize = null,

    // Status message buffer
    status_buf: [256]u8 = undefined,

    pub fn init(allocator: Allocator, reconfigure: bool) !App {
        const vx = try vaxis.Vaxis.init(allocator, .{});

        return .{
            .allocator = allocator,
            .auth = null,
            .slack_client = null,
            .socket_client = null,
            .event_queue = EventQueue.init(),
            .cache = Cache.init(allocator),
            .db = null,
            .tui_root = Root.init(),
            .vx = vx,
            .tty_buf = undefined,
            .tty = null,
            .loop = null,
            .current_channel = null,
            .reconfigure = reconfigure,
            .sidebar_entries = null,
            .message_entries = null,
            .thread_entries = null,
            .modal_items = null,
        };
    }

    pub fn deinit(self: *App) void {
        // Stop event loop
        if (self.loop) |*l| l.stop();

        // Clean up TUI
        if (self.tty) |*tty| {
            self.vx.setMouseMode(tty.writer(), false) catch {};
            self.vx.exitAltScreen(tty.writer()) catch {};
            self.vx.deinit(self.allocator, tty.writer());
            tty.deinit();
        } else {
            // Vaxis.deinit requires a writer; use a discard writer if no tty
            var discard_buf: [1]u8 = undefined;
            var discard_writer = std.fs.File.Writer.initInterface(&discard_buf);
            self.vx.deinit(self.allocator, &discard_writer);
        }

        // Clean up owned TUI data
        if (self.sidebar_entries) |entries| self.allocator.free(entries);
        if (self.message_entries) |entries| self.allocator.free(entries);
        if (self.thread_entries) |entries| self.allocator.free(entries);
        if (self.modal_items) |items| self.allocator.free(items);

        // Clean up subsystems
        self.tui_root.deinit(self.allocator);

        if (self.socket_client) |*sc| sc.disconnect();
        if (self.slack_client) |*sc| sc.deinit();
        self.cache.deinit();
        if (self.db) |*d| d.deinit();

        // Free auth strings (heap-allocated by authTest dupe)
        if (self.auth) |a| {
            // team_id and user_id are always duped by authTest or loadFromKeychain
            self.allocator.free(a.team_id);
            self.allocator.free(a.user_id);
        }
    }

    /// Main event loop.
    ///
    /// 1. Authenticate (keychain or prompt)
    /// 2. Initialize Slack client
    /// 3. Fetch channels and users
    /// 4. Connect Socket Mode
    /// 5. Run TUI event loop
    fn logStep(msg: []const u8) void {
        const stderr = std.fs.File.stderr();
        _ = stderr.write("[zlack] ") catch {};
        _ = stderr.write(msg) catch {};
        _ = stderr.write("\n") catch {};
    }

    pub fn run(self: *App) !void {
        logStep("Step 1: Authentication");
        // --- Step 1: Authentication ---
        const kc = Auth.KeychainIf{
            .save = &keychainSave,
            .load = &keychainLoad,
        };

        // Try environment variables first (for development/testing)
        const env_user_token = std.posix.getenv("ZLACK_USER_TOKEN");
        const env_app_token = std.posix.getenv("ZLACK_APP_TOKEN");

        if (env_user_token != null and env_app_token != null) {
            logStep("Step 1: Using env tokens");
            var client = SlackClient.init(self.allocator, env_user_token.?, env_app_token.?);
            defer client.deinit();
            const auth_resp = client.authTest() catch |err| {
                const name = @errorName(err);
                const stderr = std.fs.File.stderr();
                _ = stderr.write("Auth via env failed: ") catch {};
                _ = stderr.write(name) catch {};
                _ = stderr.write("\n") catch {};
                return err;
            };
            // Free unused duped fields
            if (auth_resp.team) |t| self.allocator.free(t);
            if (auth_resp.user) |u| self.allocator.free(u);
            self.auth = Auth{
                .user_token = env_user_token.?,
                .app_token = env_app_token.?,
                .team_id = auth_resp.team_id orelse return error.SlackApiError,
                .user_id = auth_resp.user_id orelse return error.SlackApiError,
            };
        }

        if (self.auth == null and !self.reconfigure) {
            // Try loading from keychain
            self.auth = try Auth.loadFromKeychain(self.allocator, "default", kc);
        }

        if (self.auth == null) {
            self.auth = Auth.promptForTokens(self.allocator) catch |err| {
                const name = @errorName(err);
                const stderr = std.fs.File.stderr();
                _ = stderr.write("Authentication failed: ") catch {};
                _ = stderr.write(name) catch {};
                _ = stderr.write("\n") catch {};
                return err;
            };
        }

        // Save to keychain (env or prompt — always persist for next launch)
        if (self.auth) |a| {
            a.saveToKeychain(kc) catch {};
        }

        const a = self.auth.?;
        logStep("Step 1: Auth OK");

        // --- Step 2: Initialize Slack client ---
        logStep("Step 2: Init Slack client");
        self.slack_client = SlackClient.init(self.allocator, a.user_token, a.app_token);

        // --- Step 3: Initialize database ---
        logStep("Step 3: Init database");
        self.db = Database.initInMemory(self.allocator) catch null;

        // --- Step 4: Initialize TUI ---
        logStep("Step 4: Init TUI");
        self.tty = try vaxis.Tty.init(&self.tty_buf);
        const tty_writer = self.tty.?.writer();
        try self.vx.enterAltScreen(tty_writer);
        try self.vx.setMouseMode(tty_writer, true);

        // Set up the event loop
        self.loop = .{ .vaxis = &self.vx, .tty = &self.tty.? };
        try self.loop.?.init();
        try self.loop.?.start();

        // Get initial winsize
        const initial_winsize = vaxis.Tty.getWinsize(self.tty.?.fd) catch null;
        if (initial_winsize) |ws| {
            try self.vx.resize(self.allocator, tty_writer, ws);
        }
        logStep("Step 4: TUI OK");

        // --- Step 5: Fetch users first (needed for DM name resolution), then channels ---
        logStep("Step 5: Fetch users");
        self.renderLoadingScreen("zlack を起動中... ユーザー一覧を取得しています");

        const api_users = self.slack_client.?.usersList() catch &.{};
        self.populateUsers(api_users);

        logStep("Step 5: Fetch channels");
        self.renderLoadingScreen("zlack を起動中... チャンネル一覧を取得しています");

        const api_channels = self.slack_client.?.conversationsList() catch &.{};
        const api_ims = self.slack_client.?.conversationsListIm();
        self.populateAllChannels(api_channels, api_ims);

        // --- Step 6: Socket Mode connection ---
        logStep("Step 6: Socket Mode");
        self.renderLoadingScreen("zlack を起動中... WebSocket に接続しています");

        const wss_url = self.slack_client.?.appsConnectionsOpen() catch null;
        if (wss_url) |url| {
            defer self.allocator.free(url);
            self.socket_client = SocketClient.init(self.allocator, &self.event_queue);
            self.socket_client.?.connect(url) catch {
                self.socket_client = null;
            };
            if (self.socket_client != null) {
                _ = self.socket_client.?.startReadLoop() catch {
                    self.socket_client.?.disconnect();
                    self.socket_client = null;
                };
            }
        }

        // --- Step 7: Update sidebar and enter main loop ---
        logStep("Step 7: Enter main loop");
        self.updateSidebar();
        self.tui_root.workspace_name = "zlack";

        // --- Main event loop ---
        try self.eventLoop();
    }

    fn eventLoop(self: *App) !void {
        while (true) {
            // Render
            const win = self.vx.window();
            self.tui_root.render(win);
            const tty_writer = self.tty.?.writer();
            try self.vx.render(tty_writer);

            // Block for next vaxis event
            const event = self.loop.?.nextEvent();
            switch (event) {
                .key_press => |key| {
                    // Clear status on any key press
                    self.tui_root.status_msg = null;
                    if (self.tui_root.handleInput(self.allocator, key)) |action| {
                        switch (action) {
                            .quit => return,
                            .select_channel => |channel_id| {
                                self.selectChannel(channel_id);
                            },
                            .send_message => |msg| {
                                self.sendMessage(msg.text, msg.thread_ts);
                                self.tui_root.input.clear();
                                if (self.current_channel) |ch| {
                                    self.refreshMessages(ch);
                                }
                            },
                            .send_also_channel => |msg| {
                                self.sendMessageBroadcast(msg.text, msg.thread_ts);
                                self.tui_root.input.clear();
                                if (self.current_channel) |ch| {
                                    self.refreshMessages(ch);
                                }
                            },
                            .upload_file => |path| {
                                self.uploadFile(path);
                                self.tui_root.input.file_mode = false;
                                self.tui_root.input.clear();
                            },
                            .download_file => |file| {
                                self.downloadFile(file);
                            },
                            .open_thread => |t| {
                                self.openThread(t.channel_id, t.thread_ts);
                                self.tui_root.input.thread_mode = true;
                                self.tui_root.focus = .input;
                            },
                            .toggle_thread => {
                                if (!self.tui_root.thread.visible) {
                                    self.tui_root.input.thread_mode = false;
                                }
                            },
                            .switch_workspace => {},
                            .search_channel => {
                                self.populateModalChannels();
                            },
                        }
                    }
                },
                .mouse => |mouse| {
                    self.handleMouse(mouse);
                },
                .winsize => |ws| {
                    const tw = self.tty.?.writer();
                    self.vx.resize(self.allocator, tw, ws) catch {};
                },
                else => {},
            }

            // Poll socket events (non-blocking)
            self.processSocketEvents();
        }
    }

    fn processSocketEvents(self: *App) void {
        while (self.event_queue.pop()) |event| {
            switch (event) {
                .message => |msg| {
                    // Add to cache
                    self.cache.addMessage(msg.channel_id, .{
                        .ts = msg.ts,
                        .user_id = msg.user,
                        .text = msg.text,
                        .thread_ts = msg.thread_ts,
                        .reply_count = 0,
                    });

                    // Check for mention
                    const is_mention = if (self.auth) |a|
                        self.textContainsMention(msg.text, a.user_id)
                    else
                        false;

                    // Mark channel as unread/mention in sidebar
                    self.markChannelNotification(msg.channel_id, is_mention);

                    // Ring terminal bell on mention
                    if (is_mention) {
                        if (self.tty) |*tty| {
                            _ = tty.writer().writeAll("\x07") catch {};
                        }
                    }

                    // If this is the current channel, refresh messages
                    if (self.current_channel) |ch| {
                        if (std.mem.eql(u8, ch, msg.channel_id)) {
                            self.updateMessages(ch);
                        }
                    }
                },
                .channel_marked => {},
                .reconnect_requested => {
                    self.reconnect();
                },
                .error_event => {},
            }
        }
    }

    fn reconnect(self: *App) void {
        if (self.socket_client) |*sc| sc.disconnect();
        self.socket_client = null;

        if (self.slack_client) |*client| {
            const url = client.appsConnectionsOpen() catch return;
            defer self.allocator.free(url);
            self.socket_client = SocketClient.init(self.allocator, &self.event_queue);
            self.socket_client.?.connect(url) catch {
                self.socket_client = null;
                return;
            };
            _ = self.socket_client.?.startReadLoop() catch {
                self.socket_client.?.disconnect();
                self.socket_client = null;
            };
        }
    }

    fn selectChannel(self: *App, channel_id: []const u8) void {
        self.current_channel = channel_id;
        self.tui_root.messages.channel_id = channel_id;
        // Close thread when switching channels
        self.tui_root.thread.hide();
        self.tui_root.input.thread_mode = false;
        // Clear unread/mention badge for this channel
        if (self.sidebar_entries) |entries| {
            for (entries) |*entry| {
                if (std.mem.eql(u8, entry.id, channel_id)) {
                    entry.has_unread = false;
                    entry.has_mention = false;
                    break;
                }
            }
        }
        self.refreshMessages(channel_id);
    }

    /// Refresh messages without closing thread pane.
    fn refreshMessages(self: *App, channel_id: []const u8) void {
        if (self.slack_client) |*client| {
            // Clear stale cache and re-fetch from API
            self.cache.clearChannelMessages(channel_id);
            const api_messages = client.conversationsHistory(channel_id, .{}) catch &.{};
            for (api_messages) |msg| {
                const first_file = if (msg.files) |files| if (files.len > 0) &files[0] else null else null;
                self.cache.addMessage(channel_id, .{
                    .ts = msg.ts,
                    .user_id = msg.user,
                    .text = msg.text,
                    .thread_ts = msg.thread_ts,
                    .reply_count = if (msg.reply_count) |rc| rc else 0,
                    .file_name = if (first_file) |f| f.name else null,
                    .file_url = if (first_file) |f| f.url_private else null,
                    .file_size = if (first_file) |f| f.size orelse 0 else 0,
                });
            }
        }
        self.updateMessages(channel_id);
    }

    fn openThread(self: *App, channel_id: []const u8, thread_ts: []const u8) void {
        {
            const stderr = std.fs.File.stderr();
            _ = stderr.write("[zlack] openThread: ch=") catch {};
            _ = stderr.write(channel_id) catch {};
            _ = stderr.write(" ts=") catch {};
            _ = stderr.write(thread_ts) catch {};
            _ = stderr.write("\n") catch {};
        }
        if (self.slack_client == null) return;
        var client = &self.slack_client.?;

        // Fetch replies
        const api_replies = client.conversationsReplies(channel_id, thread_ts) catch &.{};
        if (api_replies.len == 0) return;

        // Free previous thread entries
        if (self.thread_entries) |entries| self.allocator.free(entries);

        const entries = self.allocator.alloc(Messages.MessageEntry, api_replies.len) catch return;
        for (api_replies, 0..) |msg, i| {
            const user_name = if (msg.user) |uid|
                self.cache.getUserName(uid) orelse uid
            else
                "system";
            entries[i] = .{
                .ts = msg.ts,
                .user_name = user_name,
                .text = msg.text,
                .thread_ts = msg.thread_ts,
                .reply_count = if (msg.reply_count) |rc| rc else 0,
            };
        }
        self.thread_entries = entries;

        // First entry is parent, rest are replies
        const parent = entries[0];
        const replies = if (entries.len > 1) entries[1..] else &[_]Messages.MessageEntry{};
        self.tui_root.thread.show(parent, replies);
        {
            const stderr = std.fs.File.stderr();
            _ = stderr.write("[zlack] thread.visible=") catch {};
            _ = stderr.write(if (self.tui_root.thread.visible) "true" else "false") catch {};
            var cnt_buf: [8]u8 = undefined;
            const cnt_str = std.fmt.bufPrint(&cnt_buf, " replies={d}\n", .{replies.len}) catch "\n";
            _ = stderr.write(cnt_str) catch {};
        }
    }

    fn sendMessageBroadcast(self: *App, text: []const u8, thread_ts: []const u8) void {
        if (self.current_channel == null) return;
        const resolved = self.resolveMentions(text);
        defer if (resolved.ptr != text.ptr) self.allocator.free(resolved);
        if (self.slack_client) |*client| {
            client.chatPostMessageBroadcast(self.current_channel.?, resolved, thread_ts) catch {};
        }
    }

    fn downloadFile(self: *App, file: Messages.FileInfo) void {
        if (self.slack_client == null) return;
        var client = &self.slack_client.?;

        const home = std.posix.getenv("HOME") orelse return;
        const safe_name = security.sanitizeFilename(file.name);
        var path_buf: [1024]u8 = undefined;
        const save_path = std.fmt.bufPrint(&path_buf, "{s}/Downloads/{s}", .{ home, safe_name }) catch return;

        self.tui_root.status_msg = "Downloading...";

        const stderr = std.fs.File.stderr();
        _ = stderr.write("[zlack] downloading: ") catch {};
        _ = stderr.write(save_path) catch {};
        _ = stderr.write("\n") catch {};

        client.downloadFile(file.url, save_path) catch |err| {
            _ = stderr.write("[zlack] download failed: ") catch {};
            _ = stderr.write(@errorName(err)) catch {};
            _ = stderr.write("\n") catch {};
            self.tui_root.status_msg = "Download failed!";
            return;
        };

        _ = stderr.write("[zlack] download complete\n") catch {};
        // Show saved path in status (use static buffer for display)
        const msg = std.fmt.bufPrint(&self.status_buf, "Saved: ~/Downloads/{s}", .{file.name}) catch "Download complete!";
        self.tui_root.status_msg = msg;
    }

    fn uploadFile(self: *App, path: []const u8) void {
        if (self.current_channel == null) return;
        if (self.slack_client) |*client| {
            // Trim whitespace from path
            const trimmed = std.mem.trim(u8, path, " \t\r\n");
            {
                const stderr = std.fs.File.stderr();
                _ = stderr.write("[zlack] uploading: '") catch {};
                _ = stderr.write(trimmed) catch {};
                _ = stderr.write("'\n") catch {};
            }
            client.filesUpload(self.current_channel.?, trimmed) catch |err| {
                const name = @errorName(err);
                const stderr = std.fs.File.stderr();
                _ = stderr.write("[zlack] upload failed: ") catch {};
                _ = stderr.write(name) catch {};
                _ = stderr.write("\n") catch {};
                return;
            };
            // Refresh messages to show the uploaded file
            if (self.current_channel) |ch| {
                self.refreshMessages(ch);
            }
        }
    }

    fn sendMessage(self: *App, text: []const u8, thread_ts: ?[]const u8) void {
        if (self.current_channel == null) return;
        const resolved = self.resolveMentions(text);
        defer if (resolved.ptr != text.ptr) self.allocator.free(resolved);
        if (self.slack_client) |*client| {
            client.chatPostMessage(self.current_channel.?, resolved, thread_ts) catch {
                if (self.db) |*db| {
                    db.enqueueMessage("default", self.current_channel.?, thread_ts, resolved) catch {};
                }
            };
        }
    }

    /// Replace @name with <@USER_ID> for Slack mentions.
    fn resolveMentions(self: *App, text: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, text, '@') == null) return text;

        var result: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        var modified = false;

        while (i < text.len) {
            if (text[i] == '@') {
                const start = i + 1;
                var end = start;
                while (end < text.len and text[end] != ' ' and text[end] != '\n' and text[end] != '\t') : (end += 1) {}
                const name = text[start..end];
                if (name.len > 0) {
                    if (self.cache.getUserIdByName(name)) |uid| {
                        if (!modified) {
                            // Copy everything before this @
                            result.appendSlice(self.allocator, text[0..i]) catch return text;
                            modified = true;
                        }
                        result.appendSlice(self.allocator, "<@") catch return text;
                        result.appendSlice(self.allocator, uid) catch return text;
                        result.appendSlice(self.allocator, ">") catch return text;
                        i = end;
                        continue;
                    }
                }
            }
            if (modified) {
                result.append(self.allocator, text[i]) catch return text;
            }
            i += 1;
        }

        if (!modified) {
            result.deinit(self.allocator);
            return text;
        }
        return result.toOwnedSlice(self.allocator) catch text;
    }

    // --- Data population helpers ---

    fn populateAllChannels(self: *App, api_channels: []const types.Channel, api_ims: []const types.Channel) void {
        var cached: std.ArrayList(CachedChannel) = .empty;
        defer cached.deinit(self.allocator);

        // Regular channels
        for (api_channels) |ch| {
            const channel_type: []const u8 = if (ch.is_group != null and ch.is_group.?)
                "private_channel"
            else
                "public_channel";

            cached.append(self.allocator, .{
                .id = ch.id,
                .name = ch.name,
                .is_member = if (ch.is_member) |m| m else false,
                .channel_type = channel_type,
            }) catch continue;
        }

        // DMs (im)
        for (api_ims) |ch| {
            const name: []const u8 = if (ch.user) |uid|
                self.cache.getUserName(uid) orelse uid
            else
                "DM";

            cached.append(self.allocator, .{
                .id = ch.id,
                .name = name,
                .is_member = true,
                .channel_type = "im",
            }) catch continue;
        }

        self.cache.updateChannels(cached.items);
    }

    fn populateUsers(self: *App, api_users: []const types.User) void {
        var cached: std.ArrayList(CachedUser) = .empty;
        defer cached.deinit(self.allocator);

        for (api_users) |u| {
            cached.append(self.allocator, .{
                .id = u.id,
                .name = u.name,
                .display_name = u.display_name orelse u.real_name,
            }) catch continue;
        }

        self.cache.updateUsers(cached.items);
    }

    fn updateSidebar(self: *App) void {
        // Free previous entries
        if (self.sidebar_entries) |entries| self.allocator.free(entries);

        const channels = self.cache.getChannels();
        defer self.allocator.free(channels);

        const entries = self.allocator.alloc(Sidebar.ChannelEntry, channels.len) catch return;
        for (channels, 0..) |ch, i| {
            const is_im = std.mem.eql(u8, ch.channel_type, "im");
            entries[i] = .{
                .id = ch.id,
                .name = ch.name,
                .is_private = std.mem.eql(u8, ch.channel_type, "private_channel"),
                .is_im = is_im,
                .section = if (is_im) .dms else .channels,
                .has_unread = false,
            };
        }

        // Sort by section order (channels first, then DMs)
        std.mem.sort(Sidebar.ChannelEntry, entries, {}, struct {
            fn lessThan(_: void, a: Sidebar.ChannelEntry, b: Sidebar.ChannelEntry) bool {
                const oa = @intFromEnum(a.section);
                const ob = @intFromEnum(b.section);
                return oa < ob;
            }
        }.lessThan);

        self.sidebar_entries = entries;
        self.tui_root.sidebar.setChannels(entries);
    }

    fn updateMessages(self: *App, channel_id: []const u8) void {
        // Free previous entries
        if (self.message_entries) |entries| self.allocator.free(entries);

        const cached_msgs = self.cache.getMessages(channel_id) orelse {
            self.message_entries = null;
            self.tui_root.messages.setMessages(&.{});
            return;
        };

        const entries = self.allocator.alloc(Messages.MessageEntry, cached_msgs.len) catch return;
        for (cached_msgs, 0..) |msg, i| {
            const user_name = if (msg.user_id) |uid|
                self.cache.getUserName(uid) orelse uid
            else
                "system";
            entries[i] = .{
                .ts = msg.ts,
                .user_name = user_name,
                .text = msg.text,
                .thread_ts = msg.thread_ts,
                .reply_count = msg.reply_count,
                .file = if (msg.file_name != null and msg.file_url != null) .{
                    .name = msg.file_name.?,
                    .url = msg.file_url.?,
                    .size = msg.file_size,
                } else null,
            };
        }

        self.message_entries = entries;
        self.tui_root.messages.setMessages(entries);
    }

    fn populateModalChannels(self: *App) void {
        if (self.modal_items) |items| self.allocator.free(items);

        const channels = self.cache.getChannels();
        defer self.allocator.free(channels);

        const items = self.allocator.alloc(Modal.ModalItem, channels.len) catch return;
        for (channels, 0..) |ch, i| {
            items[i] = .{
                .id = ch.id,
                .display_name = ch.name,
            };
        }

        self.modal_items = items;
        if (self.tui_root.modal) |*m| {
            m.setItems(self.allocator, items);
        }
    }

    fn handleMouse(self: *App, raw_mouse: Mouse) void {
        const mouse = self.vx.translateMouse(raw_mouse);
        const col: u16 = @intCast(@max(0, mouse.col));
        const row: u16 = @intCast(@max(0, mouse.row));
        const sidebar_w: u16 = 20;
        const total_h = self.vx.window().height;
        const input_top = total_h -| 2;

        // --- Left click: focus + select ---
        if (mouse.button == .left and mouse.type == .press) {
            if (row >= input_top) {
                // Input area
                self.tui_root.focus = .input;
            } else if (row >= 1 and col < sidebar_w) {
                // Sidebar — calculate which channel was clicked
                self.tui_root.focus = .sidebar;
                const click_offset = @as(usize, row - 1); // row 1 = first sidebar row
                // Map display row to channel index (account for section headers)
                if (self.mapSidebarRowToIndex(click_offset)) |idx| {
                    self.tui_root.sidebar.selected_idx = idx;
                    // Double-purpose: single click selects, so also open the channel
                    self.selectChannel(self.tui_root.sidebar.channels[idx].id);
                    self.tui_root.focus = .input;
                }
            } else if (row >= 1) {
                // Messages area
                self.tui_root.focus = .messages;
                const click_row = @as(usize, row - 1);
                const estimated_idx = self.tui_root.messages.scroll_offset + click_row / 2;
                if (self.tui_root.messages.messages.len > 0) {
                    const idx = @min(estimated_idx, self.tui_root.messages.messages.len - 1);
                    self.tui_root.messages.selected_idx = idx;

                    // Double-click detection: open thread
                    const now = std.time.milliTimestamp();
                    if (self.last_click_msg_idx != null and self.last_click_msg_idx.? == idx and
                        (now - self.last_click_time) < 500)
                    {
                        const msg = self.tui_root.messages.messages[idx];
                        const tts = msg.thread_ts orelse msg.ts;
                        self.openThread(self.tui_root.messages.channel_id, tts);
                        self.tui_root.input.thread_mode = true;
                        self.tui_root.focus = .input;
                        self.last_click_msg_idx = null;
                    } else {
                        self.last_click_time = now;
                        self.last_click_msg_idx = idx;
                    }
                }
            }
            return;
        }

        // --- Wheel scroll ---
        if (mouse.button != .wheel_up and mouse.button != .wheel_down) return;

        const scroll_amount: usize = 3;
        if (col < sidebar_w) {
            if (mouse.button == .wheel_down) {
                self.tui_root.sidebar.selected_idx = @min(
                    self.tui_root.sidebar.selected_idx + scroll_amount,
                    if (self.tui_root.sidebar.channels.len > 0) self.tui_root.sidebar.channels.len - 1 else 0,
                );
            } else {
                self.tui_root.sidebar.selected_idx = if (self.tui_root.sidebar.selected_idx >= scroll_amount)
                    self.tui_root.sidebar.selected_idx - scroll_amount
                else
                    0;
            }
        } else {
            if (mouse.button == .wheel_down) {
                self.tui_root.messages.selected_idx = @min(
                    self.tui_root.messages.selected_idx + scroll_amount,
                    if (self.tui_root.messages.messages.len > 0) self.tui_root.messages.messages.len - 1 else 0,
                );
            } else {
                self.tui_root.messages.selected_idx = if (self.tui_root.messages.selected_idx >= scroll_amount)
                    self.tui_root.messages.selected_idx - scroll_amount
                else
                    0;
            }
        }
    }

    /// Map a sidebar display row (0-based from content top) to a channel index,
    /// accounting for section headers, blank separators, and scroll offset.
    fn mapSidebarRowToIndex(self: *App, target_row: usize) ?usize {
        const absolute_row = target_row + self.tui_root.sidebar.scroll_offset;
        var display_row: usize = 0;
        var prev_section: ?Sidebar.Section = null;
        for (self.tui_root.sidebar.channels, 0..) |ch, i| {
            if (prev_section == null or prev_section.? != ch.section) {
                if (prev_section != null) display_row += 1; // blank line
                display_row += 1; // section header
                prev_section = ch.section;
            }
            if (display_row == absolute_row) return i;
            display_row += 1;
        }
        return null;
    }

    /// Check if text contains a mention of the given user_id (as <@USER_ID>).
    fn textContainsMention(_: *App, text: []const u8, user_id: []const u8) bool {
        // Look for <@USER_ID> pattern
        var i: usize = 0;
        while (i + 3 + user_id.len <= text.len) : (i += 1) {
            if (text[i] == '<' and text[i + 1] == '@') {
                const start = i + 2;
                if (start + user_id.len <= text.len and
                    std.mem.eql(u8, text[start .. start + user_id.len], user_id))
                {
                    const end = start + user_id.len;
                    if (end < text.len and text[end] == '>') return true;
                }
            }
        }
        return false;
    }

    /// Mark a channel in the sidebar as having unread messages or mentions.
    fn markChannelNotification(self: *App, channel_id: []const u8, is_mention: bool) void {
        if (self.sidebar_entries) |entries| {
            for (entries) |*entry| {
                if (std.mem.eql(u8, entry.id, channel_id)) {
                    entry.has_unread = true;
                    if (is_mention) entry.has_mention = true;
                    break;
                }
            }
        }
    }

    fn renderLoadingScreen(self: *App, message: []const u8) void {
        const win = self.vx.window();
        win.clear();
        _ = win.printSegment(.{ .text = message, .style = .{ .bold = true } }, .{});
        const tty_writer = self.tty.?.writer();
        self.vx.render(tty_writer) catch {};
    }

    // --- Keychain adapter functions ---

    fn keychainSave(service: []const u8, account: []const u8, password: []const u8) anyerror!void {
        return Keychain.save(service, account, password);
    }

    fn keychainLoad(allocator: Allocator, service: []const u8, account: []const u8) anyerror!?[]const u8 {
        return Keychain.load(allocator, service, account);
    }
};
