const std = @import("std");
const Allocator = std.mem.Allocator;

const auth_mod = @import("slack/auth.zig");
const api_mod = @import("slack/api.zig");
const socket_mod = @import("slack/socket.zig");
const cache_mod = @import("store/cache.zig");
const keychain_mod = @import("platform/keychain.zig");
const types = @import("slack/types.zig");
const time_fmt = @import("time_fmt.zig");
const security = @import("security.zig");

const Auth = auth_mod.Auth;
const SlackClient = api_mod.SlackClient;
const SocketClient = socket_mod.SocketClient;
const EventQueue = socket_mod.EventQueue;
const Cache = cache_mod.Cache;
const Keychain = keychain_mod.Keychain;

/// Headless tail mode — prints messages to stdout or per-channel log files.
/// No TUI, no persistent storage. Slack ToS compliant.
pub const TailRunner = struct {
    allocator: Allocator,
    auth: ?Auth = null,
    slack_client: ?SlackClient = null,
    socket_client: ?SocketClient = null,
    event_queue: EventQueue,
    cache: Cache,
    channel_names: []const []const u8,
    channel_ids: std.StringArrayHashMapUnmanaged([]const u8), // name -> id
    channel_names_by_id: std.StringArrayHashMapUnmanaged([]const u8), // id -> name
    tail_dir: ?[]const u8,
    multi_channel: bool,
    running: bool = true,
    // Per-channel file handles (only used with --tail-dir)
    file_handles: std.StringArrayHashMapUnmanaged(std.fs.File),

    pub fn init(allocator: Allocator, channel_names: []const []const u8, tail_dir: ?[]const u8) TailRunner {
        return .{
            .allocator = allocator,
            .event_queue = EventQueue.init(),
            .cache = Cache.init(allocator),
            .channel_names = channel_names,
            .channel_ids = .{},
            .channel_names_by_id = .{},
            .tail_dir = tail_dir,
            .multi_channel = channel_names.len > 1,
            .file_handles = .{},
        };
    }

    pub fn deinit(self: *TailRunner) void {
        // Close file handles
        for (self.file_handles.values()) |*f| {
            f.close();
        }
        self.file_handles.deinit(self.allocator);
        self.channel_ids.deinit(self.allocator);
        self.channel_names_by_id.deinit(self.allocator);

        if (self.socket_client) |*sc| sc.disconnect();
        if (self.slack_client) |*sc| sc.deinit();
        self.cache.deinit();
    }

    pub fn run(self: *TailRunner) !void {
        // --- Step 1: Authenticate ---
        const stderr = std.fs.File.stderr();
        _ = stderr.write("[zlack-tail] Authenticating...\n") catch {};

        const kc = Auth.KeychainIf{
            .save = &keychainSave,
            .load = &keychainLoad,
        };

        const env_user_token = std.posix.getenv("ZLACK_USER_TOKEN");
        const env_app_token = std.posix.getenv("ZLACK_APP_TOKEN");

        if (env_user_token != null and env_app_token != null) {
            var client = SlackClient.init(self.allocator, env_user_token.?, env_app_token.?);
            defer client.deinit();
            const auth_resp = client.authTest() catch return error.AuthFailed;
            if (auth_resp.team) |t| self.allocator.free(t);
            if (auth_resp.user) |u| self.allocator.free(u);
            self.auth = Auth{
                .user_token = env_user_token.?,
                .app_token = env_app_token.?,
                .team_id = auth_resp.team_id orelse return error.AuthFailed,
                .user_id = auth_resp.user_id orelse return error.AuthFailed,
            };
        }

        if (self.auth == null) {
            self.auth = try Auth.loadFromKeychain(self.allocator, "default", kc);
        }

        if (self.auth == null) {
            self.auth = Auth.promptForTokens(self.allocator) catch return error.AuthFailed;
        }

        if (self.auth) |a| {
            a.saveToKeychain(kc) catch {};
        }

        const a = self.auth orelse return error.AuthFailed;

        // --- Step 2: Init Slack client ---
        self.slack_client = SlackClient.init(self.allocator, a.user_token, a.app_token);

        // --- Step 3: Fetch users and channels ---
        _ = stderr.write("[zlack-tail] Fetching users and channels...\n") catch {};

        const api_users = self.slack_client.?.usersList() catch &.{};
        {
            var cached_users: std.ArrayList(cache_mod.CachedUser) = .empty;
            defer cached_users.deinit(self.allocator);
            for (api_users) |u| {
                cached_users.append(self.allocator, .{
                    .id = u.id,
                    .name = u.name,
                    .display_name = u.display_name orelse u.real_name,
                }) catch continue;
            }
            self.cache.updateUsers(cached_users.items);
        }

        const api_channels = self.slack_client.?.conversationsList() catch &.{};
        const api_ims = self.slack_client.?.conversationsListIm();

        // --- Step 4: Resolve channel names to IDs ---
        try self.resolveChannelNames(api_channels, api_ims);

        _ = stderr.write("[zlack-tail] Channels resolved. Connecting...\n") catch {};

        // --- Step 5: Open file handles if --tail-dir ---
        if (self.tail_dir) |dir| {
            std.fs.cwd().makePath(dir) catch {};
            var iter = self.channel_ids.iterator();
            while (iter.next()) |entry| {
                const name = entry.key_ptr.*;
                const safe_name = security.sanitizeFilename(name);
                var path_buf: [1024]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.log", .{ dir, safe_name }) catch continue;
                const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch continue;
                file.seekFromEnd(0) catch {};
                self.file_handles.put(self.allocator, entry.value_ptr.*, file) catch continue;
            }
        }

        // --- Step 6: Connect Socket Mode (before history fetch to avoid URL expiry) ---
        const wss_url = self.slack_client.?.appsConnectionsOpen() catch {
            _ = stderr.write("[zlack-tail] Failed to get Socket Mode URL\n") catch {};
            return error.SocketModeFailed;
        };
        defer self.allocator.free(wss_url);

        self.socket_client = SocketClient.init(self.allocator, &self.event_queue);
        self.socket_client.?.connect(wss_url) catch |err| {
            _ = stderr.write("[zlack-tail] WebSocket connect error: ") catch {};
            _ = stderr.write(@errorName(err)) catch {};
            _ = stderr.write("\n") catch {};
            return error.SocketModeFailed;
        };
        _ = self.socket_client.?.startReadLoop() catch |err| {
            _ = stderr.write("[zlack-tail] Read loop error: ") catch {};
            _ = stderr.write(@errorName(err)) catch {};
            _ = stderr.write("\n") catch {};
            return error.SocketModeFailed;
        };

        // --- Step 7: Fetch initial history (after WebSocket connected) ---
        self.fetchInitialHistory();

        _ = stderr.write("[zlack-tail] Connected. Tailing messages... (Ctrl+C to stop)\n") catch {};

        // --- Step 8: Tail loop ---
        self.tailLoop();
    }

    fn resolveChannelNames(self: *TailRunner, api_channels: []const types.Channel, api_ims: []const types.Channel) !void {
        for (self.channel_names) |name| {
            var found = false;
            // Search in regular channels
            for (api_channels) |ch| {
                if (eqlIgnoreCase(ch.name, name)) {
                    self.channel_ids.put(self.allocator, name, ch.id) catch continue;
                    self.channel_names_by_id.put(self.allocator, ch.id, ch.name) catch continue;
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Search in IMs — match by display_name, login name, or user ID
                for (api_ims) |ch| {
                    if (ch.user) |uid| {
                        const display_name = self.cache.getUserName(uid) orelse uid;
                        const login_name = self.cache.getUserLoginName(uid);
                        if (eqlIgnoreCase(display_name, name) or
                            (login_name != null and eqlIgnoreCase(login_name.?, name)) or
                            eqlIgnoreCase(uid, name))
                        {
                            self.channel_ids.put(self.allocator, name, ch.id) catch continue;
                            self.channel_names_by_id.put(self.allocator, ch.id, display_name) catch continue;
                            found = true;
                            break;
                        }
                    }
                }
            }
            if (!found) {
                const stderr = std.fs.File.stderr();
                _ = stderr.write("[zlack-tail] Channel not found: ") catch {};
                _ = stderr.write(name) catch {};
                _ = stderr.write("\n") catch {};
            }
        }

        if (self.channel_ids.count() == 0) {
            return error.NoChannelsFound;
        }
    }

    fn fetchInitialHistory(self: *TailRunner) void {
        var client = &(self.slack_client orelse return);
        var iter = self.channel_ids.iterator();
        while (iter.next()) |entry| {
            const channel_id = entry.value_ptr.*;
            const channel_name = self.channel_names_by_id.get(channel_id) orelse "unknown";
            const messages = client.conversationsHistory(channel_id, .{ .limit = 10 }) catch continue;

            // Print in chronological order (API returns newest first)
            var i: usize = messages.len;
            while (i > 0) {
                i -= 1;
                const msg = messages[i];
                const user_name = if (msg.user) |uid| self.cache.getUserName(uid) orelse uid else "system";
                self.outputMessage(channel_name, channel_id, user_name, msg.ts, msg.text);
            }
        }
    }

    fn tailLoop(self: *TailRunner) void {
        const stderr = std.fs.File.stderr();
        while (self.running) {
            if (self.event_queue.pop()) |event| {
                switch (event) {
                    .message => |msg| {
                        if (self.channel_names_by_id.get(msg.channel_id)) |channel_name| {
                            const user_name = if (msg.user) |uid| self.cache.getUserName(uid) orelse uid else "system";
                            self.outputMessage(channel_name, msg.channel_id, user_name, msg.ts, msg.text);
                        }
                    },
                    .reconnect_requested => {
                        _ = stderr.write("[zlack-tail] Disconnected. Reconnecting...\n") catch {};
                        self.reconnectWithRetry();
                    },
                    .error_event => |msg| {
                        _ = stderr.write("[zlack-tail] Socket error: ") catch {};
                        _ = stderr.write(msg) catch {};
                        _ = stderr.write("\n") catch {};
                    },
                    .channel_marked => {},
                }
            } else {
                // Check if socket is dead (no client) and try to reconnect
                if (self.socket_client == null) {
                    _ = stderr.write("[zlack-tail] Socket lost. Reconnecting...\n") catch {};
                    self.reconnectWithRetry();
                }
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }
    }

    fn outputMessage(self: *TailRunner, channel_name: []const u8, channel_id: []const u8, user_name: []const u8, ts: []const u8, text: []const u8) void {
        var time_buf: [20]u8 = undefined;
        const time_str = time_fmt.formatSlackTs(ts, &time_buf);

        if (self.tail_dir != null) {
            // Write to per-channel file
            if (self.file_handles.get(channel_id)) |file| {
                var buf: [4096]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "{s} @{s}: {s}\n", .{ time_str, user_name, text }) catch return;
                _ = file.write(line) catch {};
            }
        } else {
            // Write to stdout
            const stdout = std.fs.File.stdout();
            if (self.multi_channel) {
                var buf: [4096]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "[#{s}] {s} @{s}: {s}\n", .{ channel_name, time_str, user_name, text }) catch return;
                _ = stdout.write(line) catch {};
            } else {
                var buf: [4096]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "{s} @{s}: {s}\n", .{ time_str, user_name, text }) catch return;
                _ = stdout.write(line) catch {};
            }
        }
    }

    fn reconnectWithRetry(self: *TailRunner) void {
        const stderr = std.fs.File.stderr();

        if (self.socket_client) |*sc| sc.disconnect();
        self.socket_client = null;

        var attempt: u32 = 0;
        while (attempt < 5 and self.running) : (attempt += 1) {
            if (attempt > 0) {
                const backoff_ms = socket_mod.calculateBackoff(attempt);
                var backoff_buf: [64]u8 = undefined;
                const backoff_msg = std.fmt.bufPrint(&backoff_buf, "[zlack-tail] Retry {d}/5 in {d}ms...\n", .{ attempt + 1, backoff_ms }) catch "[zlack-tail] Retrying...\n";
                _ = stderr.write(backoff_msg) catch {};
                std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
            }

            if (self.slack_client) |*client| {
                // Reset HTTP client for fresh connection
                client.http_client.deinit();
                client.http_client = std.http.Client{ .allocator = self.allocator };

                const url = client.appsConnectionsOpen() catch continue;
                defer self.allocator.free(url);

                self.socket_client = SocketClient.init(self.allocator, &self.event_queue);
                self.socket_client.?.connect(url) catch {
                    self.socket_client = null;
                    continue;
                };
                _ = self.socket_client.?.startReadLoop() catch {
                    if (self.socket_client) |*sc| sc.disconnect();
                    self.socket_client = null;
                    continue;
                };

                _ = stderr.write("[zlack-tail] Reconnected successfully.\n") catch {};
                return;
            }
        }

        _ = stderr.write("[zlack-tail] Failed to reconnect after 5 attempts.\n") catch {};
    }

    fn keychainSave(service: []const u8, account: []const u8, password: []const u8) anyerror!void {
        return Keychain.save(service, account, password);
    }

    fn keychainLoad(allocator: Allocator, service: []const u8, account: []const u8) anyerror!?[]const u8 {
        return Keychain.load(allocator, service, account);
    }
};

/// Case-insensitive string comparison for channel name matching.
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

// ===========================================================================
// Tests
// ===========================================================================

test "eqlIgnoreCase matches same case" {
    try std.testing.expect(eqlIgnoreCase("general", "general"));
}

test "eqlIgnoreCase matches different case" {
    try std.testing.expect(eqlIgnoreCase("General", "general"));
    try std.testing.expect(eqlIgnoreCase("GENERAL", "general"));
}

test "eqlIgnoreCase rejects different strings" {
    try std.testing.expect(!eqlIgnoreCase("general", "random"));
}

test "eqlIgnoreCase rejects different lengths" {
    try std.testing.expect(!eqlIgnoreCase("gen", "general"));
}

test "eqlIgnoreCase empty strings" {
    try std.testing.expect(eqlIgnoreCase("", ""));
}
