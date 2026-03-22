const std = @import("std");
const types = @import("types.zig");
const pagination = @import("pagination.zig");

const Allocator = std.mem.Allocator;

const base_url = "https://slack.com/api/";

// --- Retry logic (pure function, unit-testable) ---

pub const RetryAction = union(enum) {
    success: void,
    wait_ms: u64,
    give_up: void,
};

/// Determine retry action based on HTTP status code, attempt number, and Retry-After header.
///
/// Preconditions:
///   - attempt >= 1 (1-based)
///   - retry_after_header, if present, contains a decimal integer (seconds)
///
/// Postconditions:
///   - 200-299 -> .success
///   - 429 -> .wait_ms (from Retry-After header in ms, or default 5000ms)
///   - 500-599, attempt <= 3 -> .wait_ms with exponential backoff (1000 * 2^(attempt-1))
///   - 500-599, attempt > 3 -> .give_up
///   - all other status codes -> .give_up
pub fn shouldRetry(status_code: u16, attempt: u32, retry_after_header: ?[]const u8) RetryAction {
    if (status_code >= 200 and status_code <= 299) {
        return .success;
    }

    if (status_code == 429) {
        if (retry_after_header) |header| {
            const seconds = std.fmt.parseInt(u64, header, 10) catch 5;
            return .{ .wait_ms = seconds * 1000 };
        }
        return .{ .wait_ms = 5000 };
    }

    if (status_code >= 500 and status_code <= 599) {
        if (attempt <= 3) {
            const shift: u6 = @intCast(attempt - 1);
            const wait: u64 = @as(u64, 1000) << shift;
            return .{ .wait_ms = wait };
        }
        return .give_up;
    }

    return .give_up;
}

// --- JSON response parsing ---

pub const ApiError = error{
    SlackApiError,
    JsonParseFailed,
    HttpRequestFailed,
};

/// Parse a Slack API JSON response into the given type.
/// Checks the `ok` field and returns an error if false.
///
/// Preconditions:
///   - T must have a field `ok: bool`
///   - body must be valid JSON
///
/// Postconditions:
///   - Returns parsed value of type T if ok == true
///   - Returns error.SlackApiError if ok == false
///   - Returns error.JsonParseFailed if JSON is invalid
pub fn parseResponse(comptime T: type, allocator: Allocator, body: []const u8) !std.json.Parsed(T) {
    const parsed = std.json.parseFromSlice(T, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.JsonParseFailed;

    if (!parsed.value.ok) {
        parsed.deinit();
        return error.SlackApiError;
    }

    return parsed;
}

// --- SlackClient ---

pub const SlackClient = struct {
    allocator: Allocator,
    user_token: []const u8,
    app_token: []const u8,
    http_client: std.http.Client,

    /// Initialize a new SlackClient.
    ///
    /// Preconditions:
    ///   - user_token is a valid xoxp- token
    ///   - app_token is a valid xapp- token
    pub fn init(allocator: Allocator, user_token: []const u8, app_token: []const u8) SlackClient {
        return .{
            .allocator = allocator,
            .user_token = user_token,
            .app_token = app_token,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *SlackClient) void {
        self.http_client.deinit();
    }

    // --- Public API methods ---

    pub fn authTest(self: *SlackClient) !types.AuthTestResponse {
        const result = try self.apiCallParsed(types.AuthTestResponse, "auth.test", self.user_token, &.{});
        defer result.parsed.deinit();
        defer self.allocator.free(result.body);
        // Dupe strings before deinit frees the JSON arena
        return .{
            .ok = result.parsed.value.ok,
            .user_id = if (result.parsed.value.user_id) |s| try self.allocator.dupe(u8, s) else null,
            .team_id = if (result.parsed.value.team_id) |s| try self.allocator.dupe(u8, s) else null,
            .team = if (result.parsed.value.team) |s| try self.allocator.dupe(u8, s) else null,
            .user = if (result.parsed.value.user) |s| try self.allocator.dupe(u8, s) else null,
        };
    }

    pub fn conversationsList(self: *SlackClient) ![]const types.Channel {
        // Single-page fetch for MVP (avoids pagination lifetime complexity)
        const body = try self.apiCall("conversations.list", self.user_token, &.{
            .{ .name = "types", .value = "public_channel,private_channel" },
            .{ .name = "limit", .value = "200" },
            .{ .name = "exclude_archived", .value = "true" },
        });
        // body is intentionally NOT freed — parsed values reference it
        const parsed = try parseResponse(types.ConversationsListResponse, self.allocator, body);
        // parsed is intentionally NOT deinited — returned slices reference the arena
        if (parsed.value.channels) |channels| {
            return channels;
        }
        return &.{};
    }

    pub fn conversationsHistory(self: *SlackClient, channel_id: []const u8, opts: struct {
        limit: u32 = 100,
        oldest: ?[]const u8 = null,
    }) ![]const types.Message {
        var params: [3]std.http.Header = undefined;
        var count: usize = 0;
        params[count] = .{ .name = "channel", .value = channel_id };
        count += 1;
        var limit_buf: [16]u8 = undefined;
        const limit_str = std.fmt.bufPrint(&limit_buf, "{d}", .{opts.limit}) catch "100";
        params[count] = .{ .name = "limit", .value = limit_str };
        count += 1;
        if (opts.oldest) |oldest| {
            params[count] = .{ .name = "oldest", .value = oldest };
            count += 1;
        }
        const body = try self.apiCall("conversations.history", self.user_token, params[0..count]);
        // NOTE: body is NOT freed here — parsed values reference it.
        // For MVP, we accept this leak. A proper fix would deep-copy all returned strings.
        const parsed = try parseResponse(types.ConversationsHistoryResponse, self.allocator, body);
        if (parsed.value.messages) |messages| {
            return messages;
        }
        return &.{};
    }

    pub fn conversationsReplies(self: *SlackClient, channel_id: []const u8, thread_ts: []const u8) ![]const types.Message {
        const body = try self.apiCall("conversations.replies", self.user_token, &.{
            .{ .name = "channel", .value = channel_id },
            .{ .name = "ts", .value = thread_ts },
        });
        const parsed = try parseResponse(types.ConversationsRepliesResponse, self.allocator, body);
        if (parsed.value.messages) |messages| {
            return messages;
        }
        return &.{};
    }

    pub fn conversationsMark(self: *SlackClient, channel_id: []const u8, ts: []const u8) !void {
        const body = try self.apiCall("conversations.mark", self.user_token, &.{
            .{ .name = "channel", .value = channel_id },
            .{ .name = "ts", .value = ts },
        });
        defer self.allocator.free(body);
        const parsed = try parseResponse(types.SlackError, self.allocator, body);
        parsed.deinit();
    }

    pub fn chatPostMessage(self: *SlackClient, channel_id: []const u8, text: []const u8, thread_ts: ?[]const u8) !void {
        var params: [3]std.http.Header = undefined;
        var count: usize = 0;
        params[count] = .{ .name = "channel", .value = channel_id };
        count += 1;
        params[count] = .{ .name = "text", .value = text };
        count += 1;
        if (thread_ts) |tts| {
            params[count] = .{ .name = "thread_ts", .value = tts };
            count += 1;
        }
        const body = try self.apiCall("chat.postMessage", self.user_token, params[0..count]);
        defer self.allocator.free(body);
        const parsed = try parseResponse(types.SlackError, self.allocator, body);
        parsed.deinit();
    }

    pub fn usersList(self: *SlackClient) ![]const types.User {
        // Single-page fetch for MVP (avoids pagination lifetime complexity)
        const body = try self.apiCall("users.list", self.user_token, &.{
            .{ .name = "limit", .value = "200" },
        });
        const parsed = try parseResponse(types.UsersListResponse, self.allocator, body);
        if (parsed.value.members) |members| {
            return members;
        }
        return &.{};
    }

    pub fn usersInfo(self: *SlackClient, user_id: []const u8) !types.User {
        const body = try self.apiCall("users.info", self.user_token, &.{
            .{ .name = "user", .value = user_id },
        });

        // users.info returns { ok: true, user: { ... } }
        const Wrapper = struct {
            ok: bool,
            user: ?types.User = null,
        };
        const parsed = try parseResponse(Wrapper, self.allocator, body);
        if (parsed.value.user) |user| {
            return user;
        }
        return error.SlackApiError;
    }

    pub fn appsConnectionsOpen(self: *SlackClient) ![]const u8 {
        const body = try self.apiCall("apps.connections.open", self.app_token, &.{});
        defer self.allocator.free(body);
        const parsed = try parseResponse(types.AppsConnectionsOpenResponse, self.allocator, body);
        defer parsed.deinit();
        if (parsed.value.url) |url| {
            return try self.allocator.dupe(u8, url);
        }
        return error.SlackApiError;
    }

    // --- Internal helpers ---

    /// Make an HTTP POST to `https://slack.com/api/{method}` with Bearer token auth.
    /// Params are sent as application/x-www-form-urlencoded body.
    /// Handles rate limiting (429) and 5xx retries with exponential backoff.
    ///
    /// Returns the response body as an owned slice. Caller must free.
    fn apiCall(self: *SlackClient, method: []const u8, token: []const u8, params: []const std.http.Header) ![]const u8 {
        // Build URL
        var url_buf: [256]u8 = undefined;
        const url_str = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ base_url, method }) catch return error.JsonParseFailed;

        // Build form-encoded body
        var form_body: std.ArrayList(u8) = .empty;
        defer form_body.deinit(self.allocator);
        for (params, 0..) |param, i| {
            if (i > 0) try form_body.append(self.allocator, '&');
            try uriEncodeAppend(self.allocator, &form_body, param.name);
            try form_body.append(self.allocator, '=');
            try uriEncodeAppend(self.allocator, &form_body, param.value);
        }

        // Build auth header value
        var auth_buf: [256]u8 = undefined;
        const auth_str = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return error.JsonParseFailed;

        // Always send a body for POST — fetch() calls sendBodiless() for null payload,
        // which panics on POST (requestHasBody() == true).
        const payload: []const u8 = if (form_body.items.len > 0) form_body.items else "";

        var attempt: u32 = 1;
        while (true) {
            // Use fetch() with a heap-allocated response buffer
            const heap_buf = try self.allocator.alloc(u8, 1024 * 1024); // 1MB
            defer self.allocator.free(heap_buf);
            var response_writer = std.Io.Writer.fixed(heap_buf);

            const result = self.http_client.fetch(.{
                .location = .{ .url = url_str },
                .method = .POST,
                .payload = payload,
                .headers = .{
                    .authorization = .{ .override = auth_str },
                    .content_type = .{ .override = "application/x-www-form-urlencoded" },
                },
                .response_writer = &response_writer,
                .redirect_behavior = .unhandled,
            }) catch |err| {
                const stderr = std.fs.File.stderr();
                _ = stderr.write("[zlack] fetch failed: ") catch {};
                _ = stderr.write(@errorName(err)) catch {};
                _ = stderr.write("\n") catch {};
                return error.HttpRequestFailed;
            };

            const status: u16 = @intFromEnum(result.status);

            // Debug: log status
            {
                const stderr = std.fs.File.stderr();
                _ = stderr.write("[zlack] HTTP ") catch {};
                var status_str_buf: [8]u8 = undefined;
                const status_str = std.fmt.bufPrint(&status_str_buf, "{d}", .{status}) catch "???";
                _ = stderr.write(status_str) catch {};
                _ = stderr.write(" for ") catch {};
                _ = stderr.write(method) catch {};
                _ = stderr.write("\n") catch {};
            }

            // Get response body from the writer
            const written = response_writer.end;
            const response_body = try self.allocator.dupe(u8, heap_buf[0..written]);

            const action = shouldRetry(status, attempt, null);
            switch (action) {
                .success => {
                    return response_body;
                },
                .wait_ms => |ms| {
                    self.allocator.free(response_body);
                    std.Thread.sleep(ms * std.time.ns_per_ms);
                    attempt += 1;
                    continue;
                },
                .give_up => {
                    self.allocator.free(response_body);
                    return error.SlackApiError;
                },
            }
        }
    }

    /// Call API and parse response. Caller must call .deinit() on result.
    /// NOTE: The returned Parsed owns its arena which references the response body.
    /// The body is NOT freed here — it's owned by the Parsed arena or must be
    /// freed by the caller after they're done with the parsed value.
    fn apiCallParsed(self: *SlackClient, comptime T: type, method: []const u8, token: []const u8, params: []const std.http.Header) !struct { parsed: std.json.Parsed(T), body: []const u8 } {
        const body = try self.apiCall(method, token, params);
        const parsed = parseResponse(T, self.allocator, body) catch |err| {
            self.allocator.free(body);
            return err;
        };
        return .{ .parsed = parsed, .body = body };
    }
};

/// URI-encode a string and append to the buffer.
fn uriEncodeAppend(allocator: Allocator, buf: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.append(allocator, c);
        } else {
            try buf.appendSlice(allocator, &.{ '%', hexDigit(c >> 4), hexDigit(c & 0x0f) });
        }
    }
}

fn hexDigit(nibble: u8) u8 {
    return "0123456789ABCDEF"[nibble & 0x0f];
}

// =====================
// Tests
// =====================

test "shouldRetry - 200 returns success" {
    const action = shouldRetry(200, 1, null);
    try std.testing.expect(action == .success);
}

test "shouldRetry - 201 returns success" {
    const action = shouldRetry(201, 1, null);
    try std.testing.expect(action == .success);
}

test "shouldRetry - 429 with Retry-After header" {
    const action = shouldRetry(429, 1, "5");
    switch (action) {
        .wait_ms => |ms| try std.testing.expectEqual(@as(u64, 5000), ms),
        else => return error.TestUnexpectedResult,
    }
}

test "shouldRetry - 429 without Retry-After header defaults to 5000" {
    const action = shouldRetry(429, 1, null);
    switch (action) {
        .wait_ms => |ms| try std.testing.expectEqual(@as(u64, 5000), ms),
        else => return error.TestUnexpectedResult,
    }
}

test "shouldRetry - 500 attempt 1 returns 1000ms" {
    const action = shouldRetry(500, 1, null);
    switch (action) {
        .wait_ms => |ms| try std.testing.expectEqual(@as(u64, 1000), ms),
        else => return error.TestUnexpectedResult,
    }
}

test "shouldRetry - 500 attempt 2 returns 2000ms" {
    const action = shouldRetry(500, 2, null);
    switch (action) {
        .wait_ms => |ms| try std.testing.expectEqual(@as(u64, 2000), ms),
        else => return error.TestUnexpectedResult,
    }
}

test "shouldRetry - 500 attempt 3 returns 4000ms" {
    const action = shouldRetry(500, 3, null);
    switch (action) {
        .wait_ms => |ms| try std.testing.expectEqual(@as(u64, 4000), ms),
        else => return error.TestUnexpectedResult,
    }
}

test "shouldRetry - 500 attempt 4 gives up" {
    const action = shouldRetry(500, 4, null);
    try std.testing.expect(action == .give_up);
}

test "shouldRetry - 403 gives up" {
    const action = shouldRetry(403, 1, null);
    try std.testing.expect(action == .give_up);
}

test "shouldRetry - 502 attempt 1 retries" {
    const action = shouldRetry(502, 1, null);
    switch (action) {
        .wait_ms => |ms| try std.testing.expectEqual(@as(u64, 1000), ms),
        else => return error.TestUnexpectedResult,
    }
}

test "shouldRetry - 429 with Retry-After 10" {
    const action = shouldRetry(429, 1, "10");
    switch (action) {
        .wait_ms => |ms| try std.testing.expectEqual(@as(u64, 10000), ms),
        else => return error.TestUnexpectedResult,
    }
}

test "shouldRetry - 429 with invalid Retry-After falls back to 5s" {
    const action = shouldRetry(429, 1, "notanumber");
    switch (action) {
        .wait_ms => |ms| try std.testing.expectEqual(@as(u64, 5000), ms),
        else => return error.TestUnexpectedResult,
    }
}

// --- parseResponse tests ---

test "parseResponse - valid ok response" {
    const json =
        \\{"ok":true,"user_id":"U12345","team_id":"T12345","team":"myteam","user":"jdoe"}
    ;
    const parsed = try parseResponse(types.AuthTestResponse, std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.ok == true);
    try std.testing.expectEqualStrings("U12345", parsed.value.user_id.?);
    try std.testing.expectEqualStrings("T12345", parsed.value.team_id.?);
}

test "parseResponse - ok false returns SlackApiError" {
    const json =
        \\{"ok":false,"error":"invalid_auth"}
    ;
    const result = parseResponse(types.AuthTestResponse, std.testing.allocator, json);
    try std.testing.expectError(error.SlackApiError, result);
}

test "parseResponse - invalid JSON returns JsonParseFailed" {
    const result = parseResponse(types.AuthTestResponse, std.testing.allocator, "not json at all");
    try std.testing.expectError(error.JsonParseFailed, result);
}

test "parseResponse - ConversationsListResponse with channels" {
    const json =
        \\{"ok":true,"channels":[{"id":"C1","name":"general"},{"id":"C2","name":"random"}],"response_metadata":{"next_cursor":"abc"}}
    ;
    const parsed = try parseResponse(types.ConversationsListResponse, std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.channels.?.len == 2);
    try std.testing.expectEqualStrings("C1", parsed.value.channels.?[0].id);
    try std.testing.expectEqualStrings("random", parsed.value.channels.?[1].name);
    try std.testing.expectEqualStrings("abc", parsed.value.response_metadata.?.next_cursor.?);
}

test "parseResponse - AppsConnectionsOpenResponse with url" {
    const json =
        \\{"ok":true,"url":"wss://wss-primary.example.com/link"}
    ;
    const parsed = try parseResponse(types.AppsConnectionsOpenResponse, std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("wss://wss-primary.example.com/link", parsed.value.url.?);
}

test "parseResponse - UsersListResponse with members" {
    const json =
        \\{"ok":true,"members":[{"id":"U1","name":"alice"},{"id":"U2","name":"bob","is_bot":true}]}
    ;
    const parsed = try parseResponse(types.UsersListResponse, std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.members.?.len == 2);
    try std.testing.expectEqualStrings("U1", parsed.value.members.?[0].id);
    try std.testing.expect(parsed.value.members.?[1].is_bot.? == true);
}

test "parseResponse - ConversationsHistoryResponse with messages" {
    const json =
        \\{"ok":true,"messages":[{"ts":"1679000000.123456","text":"hello","user":"U1"}],"has_more":false}
    ;
    const parsed = try parseResponse(types.ConversationsHistoryResponse, std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.messages.?.len == 1);
    try std.testing.expectEqualStrings("1679000000.123456", parsed.value.messages.?[0].ts);
    try std.testing.expect(parsed.value.has_more.? == false);
}

// --- URI encoding tests ---

test "uriEncodeAppend - alphanumeric passthrough" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try uriEncodeAppend(std.testing.allocator, &buf, "hello123");
    try std.testing.expectEqualStrings("hello123", buf.items);
}

test "uriEncodeAppend - special characters encoded" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try uriEncodeAppend(std.testing.allocator, &buf, "a b&c=d");
    try std.testing.expectEqualStrings("a%20b%26c%3Dd", buf.items);
}

test "uriEncodeAppend - preserves unreserved chars" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try uriEncodeAppend(std.testing.allocator, &buf, "a-b_c.d~e");
    try std.testing.expectEqualStrings("a-b_c.d~e", buf.items);
}
