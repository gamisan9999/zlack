const std = @import("std");
const Allocator = std.mem.Allocator;

/// Function type for resolving a Slack user ID to a display name.
/// Returns null if the user is not found.
pub const UserLookupFn = *const fn (user_id: []const u8) ?[]const u8;

/// Resolves Slack mrkdwn markup to plain text for TUI display.
///
/// MVP conversions:
/// - `<@U12345>` -> `@display_name` (via user lookup; `@unknown` if not found)
/// - `<#C12345|name>` -> `#name`
/// - `<URL>` -> URL text as-is
/// - `<URL|label>` -> label text
/// - `&amp;` -> `&`, `&lt;` -> `<`, `&gt;` -> `>`
/// - `*bold*`, `_italic_`, `~strike~` -> kept as-is for MVP
pub const MrkdwnResolver = struct {
    user_lookup: UserLookupFn,

    pub fn init(user_lookup: UserLookupFn) MrkdwnResolver {
        return .{ .user_lookup = user_lookup };
    }

    /// Resolve mrkdwn text to plain text.
    /// Caller owns the returned slice and must free it with the same allocator.
    pub fn resolve(self: MrkdwnResolver, allocator: Allocator, text: []const u8) ![]u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(allocator);

        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '<') {
                // Find matching '>'
                const start = i + 1;
                const end = std.mem.indexOfScalarPos(u8, text, start, '>') orelse {
                    // No closing '>' — emit '<' literally and continue
                    try buf.append(allocator, '<');
                    i += 1;
                    continue;
                };
                const inner = text[start..end];
                try self.resolveAngleBracket(allocator, &buf, inner);
                i = end + 1;
            } else if (text[i] == '&') {
                // Try to decode HTML entity
                const consumed = try decodeEntity(allocator, &buf, text[i..]);
                i += consumed;
            } else {
                try buf.append(allocator, text[i]);
                i += 1;
            }
        }

        return buf.toOwnedSlice(allocator);
    }

    fn resolveAngleBracket(self: MrkdwnResolver, allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), inner: []const u8) !void {
        if (inner.len == 0) return;

        if (inner[0] == '@') {
            // User mention: <@U12345>
            const user_id = inner[1..];
            const name = self.user_lookup(user_id) orelse "unknown";
            try buf.append(allocator, '@');
            try buf.appendSlice(allocator, name);
        } else if (inner[0] == '#') {
            // Channel link: <#C12345|name>
            if (std.mem.indexOfScalar(u8, inner, '|')) |pipe| {
                const channel_name = inner[pipe + 1 ..];
                try buf.append(allocator, '#');
                try buf.appendSlice(allocator, channel_name);
            } else {
                // No pipe — emit as #ID
                try buf.append(allocator, '#');
                try buf.appendSlice(allocator, inner[1..]);
            }
        } else {
            // URL or URL|label
            if (std.mem.indexOfScalar(u8, inner, '|')) |pipe| {
                const label = inner[pipe + 1 ..];
                try buf.appendSlice(allocator, label);
            } else {
                try buf.appendSlice(allocator, inner);
            }
        }
    }
};

/// Decode an HTML entity at the start of `text` (which begins with '&').
/// Appends the decoded character(s) to `buf`.
/// Returns the number of bytes consumed from `text`.
fn decodeEntity(allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), text: []const u8) !usize {
    const entities = .{
        .{ "&amp;", "&" },
        .{ "&lt;", "<" },
        .{ "&gt;", ">" },
    };

    inline for (entities) |ent| {
        const pattern = ent[0];
        const replacement = ent[1];
        if (text.len >= pattern.len and std.mem.eql(u8, text[0..pattern.len], pattern)) {
            try buf.appendSlice(allocator, replacement);
            return pattern.len;
        }
    }

    // Not a recognized entity — emit '&' literally
    try buf.append(allocator, '&');
    return 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testUserLookup(user_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, user_id, "U12345")) return "user_a";
    return null;
}

test "resolve user mention" {
    const resolver = MrkdwnResolver.init(&testUserLookup);
    const result = try resolver.resolve(std.testing.allocator, "<@U12345> hello");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@user_a hello", result);
}

test "resolve unknown user mention" {
    const resolver = MrkdwnResolver.init(&testUserLookup);
    const result = try resolver.resolve(std.testing.allocator, "<@U99999> hello");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@unknown hello", result);
}

test "resolve channel link" {
    const resolver = MrkdwnResolver.init(&testUserLookup);
    const result = try resolver.resolve(std.testing.allocator, "<#C12345|general> を見て");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("#general を見て", result);
}

test "resolve URL" {
    const resolver = MrkdwnResolver.init(&testUserLookup);
    const result = try resolver.resolve(std.testing.allocator, "<https://example.com>");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com", result);
}

test "resolve URL with label" {
    const resolver = MrkdwnResolver.init(&testUserLookup);
    const result = try resolver.resolve(std.testing.allocator, "<https://example.com|Example>");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Example", result);
}

test "HTML entity decode" {
    const resolver = MrkdwnResolver.init(&testUserLookup);
    const result = try resolver.resolve(std.testing.allocator, "a &amp; b &lt; c &gt; d");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a & b < c > d", result);
}

test "plain text unchanged" {
    const resolver = MrkdwnResolver.init(&testUserLookup);
    const result = try resolver.resolve(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "multiple substitutions" {
    const resolver = MrkdwnResolver.init(&testUserLookup);
    const result = try resolver.resolve(std.testing.allocator, "<@U12345> said &lt;hello&gt; in <#C12345|general> see <https://example.com|link>");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("@user_a said <hello> in #general see link", result);
}

test "unclosed angle bracket" {
    const resolver = MrkdwnResolver.init(&testUserLookup);
    const result = try resolver.resolve(std.testing.allocator, "a < b");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a < b", result);
}

test "empty input" {
    const resolver = MrkdwnResolver.init(&testUserLookup);
    const result = try resolver.resolve(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "unrecognized entity passthrough" {
    const resolver = MrkdwnResolver.init(&testUserLookup);
    const result = try resolver.resolve(std.testing.allocator, "&foo; bar");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("&foo; bar", result);
}

test "channel without pipe" {
    const resolver = MrkdwnResolver.init(&testUserLookup);
    const result = try resolver.resolve(std.testing.allocator, "<#C12345>");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("#C12345", result);
}
