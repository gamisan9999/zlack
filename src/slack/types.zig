const std = @import("std");

// --- Core types ---

pub const Channel = struct {
    id: []const u8,
    name: []const u8,
    is_channel: ?bool = null,
    is_group: ?bool = null,
    is_im: ?bool = null,
    is_mpim: ?bool = null,
    is_member: ?bool = null,
    num_members: ?u32 = null,
};

pub const Reaction = struct {
    name: []const u8,
    count: ?u32 = null,
    users: ?[]const []const u8 = null,
};

pub const Message = struct {
    ts: []const u8,
    text: []const u8,
    user: ?[]const u8 = null,
    thread_ts: ?[]const u8 = null,
    reply_count: ?u32 = null,
    reactions: ?[]const Reaction = null,
};

pub const User = struct {
    id: []const u8,
    name: []const u8,
    real_name: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    is_bot: ?bool = null,
};

// --- API response types ---

pub const ResponseMetadata = struct {
    next_cursor: ?[]const u8 = null,
};

pub const AuthTestResponse = struct {
    ok: bool,
    user_id: ?[]const u8 = null,
    team_id: ?[]const u8 = null,
    team: ?[]const u8 = null,
    user: ?[]const u8 = null,
};

pub const ConversationsListResponse = struct {
    ok: bool,
    channels: ?[]const Channel = null,
    response_metadata: ?ResponseMetadata = null,
};

pub const ConversationsHistoryResponse = struct {
    ok: bool,
    messages: ?[]const Message = null,
    has_more: ?bool = null,
    response_metadata: ?ResponseMetadata = null,
};

pub const ConversationsRepliesResponse = struct {
    ok: bool,
    messages: ?[]const Message = null,
    has_more: ?bool = null,
    response_metadata: ?ResponseMetadata = null,
};

pub const UsersListResponse = struct {
    ok: bool,
    members: ?[]const User = null,
    response_metadata: ?ResponseMetadata = null,
};

pub const AppsConnectionsOpenResponse = struct {
    ok: bool,
    url: ?[]const u8 = null,
};

pub const SlackError = struct {
    ok: bool,
    @"error": ?[]const u8 = null,
};

// --- Tests ---

test "parse Channel from JSON" {
    const json =
        \\{"id":"C12345","name":"general","is_channel":true,"is_member":true}
    ;
    const channel = try std.json.parseFromSlice(Channel, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer channel.deinit();
    try std.testing.expectEqualStrings("C12345", channel.value.id);
    try std.testing.expectEqualStrings("general", channel.value.name);
    try std.testing.expect(channel.value.is_channel.? == true);
    try std.testing.expect(channel.value.is_member.? == true);
    try std.testing.expect(channel.value.is_group == null);
}

test "parse Message from JSON" {
    const json =
        \\{"ts":"1679000000.123456","user":"U12345","text":"hello","thread_ts":null}
    ;
    const msg = try std.json.parseFromSlice(Message, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer msg.deinit();
    try std.testing.expectEqualStrings("1679000000.123456", msg.value.ts);
    try std.testing.expectEqualStrings("hello", msg.value.text);
    try std.testing.expectEqualStrings("U12345", msg.value.user.?);
    try std.testing.expect(msg.value.thread_ts == null);
}

test "parse Message with thread_ts set" {
    const json =
        \\{"ts":"1679000000.123456","text":"reply","thread_ts":"1679000000.000001","reply_count":3}
    ;
    const msg = try std.json.parseFromSlice(Message, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer msg.deinit();
    try std.testing.expectEqualStrings("1679000000.000001", msg.value.thread_ts.?);
    try std.testing.expect(msg.value.reply_count.? == 3);
}

test "parse User from JSON" {
    const json =
        \\{"id":"U12345","name":"jdoe","real_name":"John Doe","display_name":"johnd","is_bot":false}
    ;
    const user = try std.json.parseFromSlice(User, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer user.deinit();
    try std.testing.expectEqualStrings("U12345", user.value.id);
    try std.testing.expectEqualStrings("jdoe", user.value.name);
    try std.testing.expectEqualStrings("John Doe", user.value.real_name.?);
    try std.testing.expect(user.value.is_bot.? == false);
}

test "parse ConversationsListResponse with channels array" {
    const json =
        \\{"ok":true,"channels":[{"id":"C1","name":"general"},{"id":"C2","name":"random"}],"response_metadata":{"next_cursor":"abc123"}}
    ;
    const resp = try std.json.parseFromSlice(ConversationsListResponse, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer resp.deinit();
    try std.testing.expect(resp.value.ok == true);
    try std.testing.expect(resp.value.channels.?.len == 2);
    try std.testing.expectEqualStrings("C1", resp.value.channels.?[0].id);
    try std.testing.expectEqualStrings("random", resp.value.channels.?[1].name);
    try std.testing.expectEqualStrings("abc123", resp.value.response_metadata.?.next_cursor.?);
}

test "parse SlackError from JSON" {
    const json =
        \\{"ok":false,"error":"invalid_auth"}
    ;
    const err = try std.json.parseFromSlice(SlackError, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer err.deinit();
    try std.testing.expect(err.value.ok == false);
    try std.testing.expectEqualStrings("invalid_auth", err.value.@"error".?);
}

test "parse AuthTestResponse from JSON" {
    const json =
        \\{"ok":true,"user_id":"U12345","team_id":"T12345","team":"myteam","user":"jdoe"}
    ;
    const resp = try std.json.parseFromSlice(AuthTestResponse, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer resp.deinit();
    try std.testing.expect(resp.value.ok == true);
    try std.testing.expectEqualStrings("U12345", resp.value.user_id.?);
    try std.testing.expectEqualStrings("T12345", resp.value.team_id.?);
}

test "parse AppsConnectionsOpenResponse from JSON" {
    const json =
        \\{"ok":true,"url":"wss://wss-primary.example.com/link"}
    ;
    const resp = try std.json.parseFromSlice(AppsConnectionsOpenResponse, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer resp.deinit();
    try std.testing.expect(resp.value.ok == true);
    try std.testing.expectEqualStrings("wss://wss-primary.example.com/link", resp.value.url.?);
}

test "parse ConversationsHistoryResponse from JSON" {
    const json =
        \\{"ok":true,"messages":[{"ts":"1679000000.123456","text":"hello"}],"has_more":true,"response_metadata":{"next_cursor":"next1"}}
    ;
    const resp = try std.json.parseFromSlice(ConversationsHistoryResponse, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer resp.deinit();
    try std.testing.expect(resp.value.ok == true);
    try std.testing.expect(resp.value.messages.?.len == 1);
    try std.testing.expect(resp.value.has_more.? == true);
    try std.testing.expectEqualStrings("next1", resp.value.response_metadata.?.next_cursor.?);
}

test "ignore unknown fields from Slack API" {
    const json =
        \\{"id":"C12345","name":"general","purpose":{"value":"General chat"},"topic":{"value":""},"extra_field":42}
    ;
    const channel = try std.json.parseFromSlice(Channel, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer channel.deinit();
    try std.testing.expectEqualStrings("C12345", channel.value.id);
    try std.testing.expectEqualStrings("general", channel.value.name);
}
