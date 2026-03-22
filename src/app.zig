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

const Event = vaxis.Event;
const Loop = vaxis.Loop;

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
        };
    }

    pub fn deinit(self: *App) void {
        // Stop event loop
        if (self.loop) |*l| l.stop();

        // Clean up TUI
        if (self.tty) |*tty| {
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

        // Clean up subsystems
        self.tui_root.deinit(self.allocator);

        if (self.socket_client) |*sc| sc.disconnect();
        if (self.slack_client) |*sc| sc.deinit();
        self.cache.deinit();
        if (self.db) |*d| d.deinit();
    }

    /// Main event loop.
    ///
    /// 1. Authenticate (keychain or prompt)
    /// 2. Initialize Slack client
    /// 3. Fetch channels and users
    /// 4. Connect Socket Mode
    /// 5. Run TUI event loop
    pub fn run(self: *App) !void {
        // --- Step 1: Authentication ---
        const kc = Auth.KeychainIf{
            .save = &keychainSave,
            .load = &keychainLoad,
        };

        if (!self.reconfigure) {
            // Try loading from keychain with a default team_id
            self.auth = try Auth.loadFromKeychain(self.allocator, "default", kc);
        }

        if (self.auth == null) {
            self.auth = Auth.promptForTokens(self.allocator) catch |err| {
                var stderr_buf: [256]u8 = undefined;
                var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
                stderr_w.interface.print("Authentication failed: {}\n", .{err}) catch {};
                return err;
            };
            // Save to keychain
            if (self.auth) |a| {
                a.saveToKeychain(kc) catch {};
            }
        }

        const a = self.auth.?;

        // --- Step 2: Initialize Slack client ---
        self.slack_client = SlackClient.init(self.allocator, a.user_token, a.app_token);

        // --- Step 3: Initialize database ---
        self.db = Database.initInMemory(self.allocator) catch null;

        // --- Step 4: Initialize TUI ---
        self.tty = try vaxis.Tty.init(&self.tty_buf);
        const tty_writer = self.tty.?.writer();
        try self.vx.enterAltScreen(tty_writer);

        // Set up the event loop
        self.loop = .{ .vaxis = &self.vx, .tty = &self.tty.? };
        try self.loop.?.init();
        try self.loop.?.start();

        // Get initial winsize
        const initial_winsize = vaxis.Tty.getWinsize(self.tty.?.fd) catch null;
        if (initial_winsize) |ws| {
            try self.vx.resize(self.allocator, tty_writer, ws);
        }

        // --- Step 5: Fetch channels and users, show loading ---
        self.renderLoadingScreen("zlack を起動中... チャンネル一覧を取得しています");

        const api_channels = self.slack_client.?.conversationsList() catch &.{};
        self.populateChannels(api_channels);

        self.renderLoadingScreen("zlack を起動中... ユーザー一覧を取得しています");

        const api_users = self.slack_client.?.usersList() catch &.{};
        self.populateUsers(api_users);

        // --- Step 6: Socket Mode connection ---
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
                    if (self.tui_root.handleInput(self.allocator, key)) |action| {
                        switch (action) {
                            .quit => return,
                            .select_channel => |channel_id| {
                                self.selectChannel(channel_id);
                            },
                            .send_message => |msg| {
                                self.sendMessage(msg.text, msg.thread_ts);
                            },
                            .open_thread => |_| {
                                // Thread loading would go here in a full implementation
                            },
                            .toggle_thread => {},
                            .switch_workspace => {},
                            .search_channel => {},
                        }
                    }
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

        // Fetch history via REST API
        if (self.slack_client) |*client| {
            const api_messages = client.conversationsHistory(channel_id, .{}) catch &.{};
            // Populate cache
            for (api_messages) |msg| {
                self.cache.addMessage(channel_id, .{
                    .ts = msg.ts,
                    .user_id = msg.user,
                    .text = msg.text,
                    .thread_ts = msg.thread_ts,
                    .reply_count = if (msg.reply_count) |rc| rc else 0,
                });
            }
        }

        self.updateMessages(channel_id);
    }

    fn sendMessage(self: *App, text: []const u8, thread_ts: ?[]const u8) void {
        if (self.current_channel == null) return;
        if (self.slack_client) |*client| {
            client.chatPostMessage(self.current_channel.?, text, thread_ts) catch {
                // On failure, enqueue to outbox for retry
                if (self.db) |*db| {
                    db.enqueueMessage("default", self.current_channel.?, thread_ts, text) catch {};
                }
            };
        }
    }

    // --- Data population helpers ---

    fn populateChannels(self: *App, api_channels: []const types.Channel) void {
        var cached: std.ArrayList(CachedChannel) = .empty;
        defer cached.deinit(self.allocator);

        for (api_channels) |ch| {
            cached.append(self.allocator, .{
                .id = ch.id,
                .name = ch.name,
                .is_member = if (ch.is_member) |m| m else false,
                .channel_type = if (ch.is_group != null and ch.is_group.?) "private_channel" else "public_channel",
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
            entries[i] = .{
                .id = ch.id,
                .name = ch.name,
                .is_private = std.mem.eql(u8, ch.channel_type, "private_channel"),
                .has_unread = false,
            };
        }

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
            };
        }

        self.message_entries = entries;
        self.tui_root.messages.setMessages(entries);
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
