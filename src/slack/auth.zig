const std = @import("std");
const api = @import("api.zig");

const Allocator = std.mem.Allocator;

/// Authentication flow combining Keychain storage and Slack API validation.
///
/// Holds user/app tokens along with team_id/user_id obtained from auth.test.
/// Keychain operations are performed via the platform module, injected at the
/// call site (main.zig) to avoid cross-directory import issues in test modules.
pub const Auth = struct {
    user_token: []const u8,
    app_token: []const u8,
    team_id: []const u8,
    user_id: []const u8,

    pub const Error = error{
        InvalidTokenFormat,
        TokenTooShort,
        EmptyToken,
    };

    const min_token_len = 10;
    const user_token_prefix = "xoxp-";
    const app_token_prefix = "xapp-";

    /// Keychain interface — injected by caller to decouple from platform module.
    pub const KeychainIf = struct {
        save: *const fn (service: []const u8, account: []const u8, password: []const u8) anyerror!void,
        load: *const fn (allocator: Allocator, service: []const u8, account: []const u8) anyerror!?[]const u8,
    };

    /// Load tokens from Keychain for a given team_id, validate with auth.test.
    /// Returns null if tokens are not found in Keychain.
    ///
    /// Preconditions:
    ///   - team_id is non-empty
    /// Postconditions:
    ///   - Returns Auth with validated team_id/user_id from Slack, or null
    pub fn loadFromKeychain(allocator: Allocator, team_id: []const u8, kc: KeychainIf) !?Auth {
        var user_service_buf: [128]u8 = undefined;
        const user_service = std.fmt.bufPrint(&user_service_buf, "zlack.user.{s}", .{team_id}) catch return null;

        var app_service_buf: [128]u8 = undefined;
        const app_service = std.fmt.bufPrint(&app_service_buf, "zlack.app.{s}", .{team_id}) catch return null;

        const user_token = try kc.load(allocator, user_service, "default") orelse return null;
        errdefer allocator.free(user_token);

        const app_token = kc.load(allocator, app_service, "default") catch {
            allocator.free(user_token);
            return null;
        } orelse {
            allocator.free(user_token);
            return null;
        };
        errdefer allocator.free(app_token);

        // Validate with auth.test
        var client = api.SlackClient.init(allocator, user_token, app_token);
        defer client.deinit();

        const auth_resp = client.authTest() catch {
            allocator.free(user_token);
            allocator.free(app_token);
            return null;
        };

        const resp_team_id = auth_resp.team_id orelse {
            allocator.free(user_token);
            allocator.free(app_token);
            return null;
        };
        const resp_user_id = auth_resp.user_id orelse {
            allocator.free(user_token);
            allocator.free(app_token);
            return null;
        };

        return Auth{
            .user_token = user_token,
            .app_token = app_token,
            .team_id = try allocator.dupe(u8, resp_team_id),
            .user_id = try allocator.dupe(u8, resp_user_id),
        };
    }

    /// Save tokens to Keychain with service names: zlack.user.{team_id}, zlack.app.{team_id}
    ///
    /// Preconditions:
    ///   - self.team_id, user_token, app_token are non-empty
    /// Postconditions:
    ///   - Tokens are stored (or updated) in Keychain
    pub fn saveToKeychain(self: Auth, kc: KeychainIf) !void {
        var user_service_buf: [128]u8 = undefined;
        const user_service = std.fmt.bufPrint(&user_service_buf, "zlack.user.{s}", .{self.team_id}) catch return error.InvalidTokenFormat;

        var app_service_buf: [128]u8 = undefined;
        const app_service = std.fmt.bufPrint(&app_service_buf, "zlack.app.{s}", .{self.team_id}) catch return error.InvalidTokenFormat;

        try kc.save(user_service, "default", self.user_token);
        try kc.save(app_service, "default", self.app_token);
    }

    /// Interactive token input from stdin/stdout.
    /// Reads xoxp- and xapp- tokens, validates format, calls auth.test, returns Auth.
    ///
    /// Postconditions:
    ///   - Returns Auth with validated tokens and team_id/user_id from Slack
    pub fn promptForTokens(allocator: Allocator) !Auth {
        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();

        try stdout.writeAll("Enter User Token (xoxp-...): ");
        const user_token = try stdin.readUntilDelimiterAlloc(allocator, '\n', 4096);
        errdefer allocator.free(user_token);

        const trimmed_user = std.mem.trimRight(u8, user_token, "\r\n ");
        try validateUserToken(trimmed_user);

        try stdout.writeAll("Enter App Token (xapp-...): ");
        const app_token = try stdin.readUntilDelimiterAlloc(allocator, '\n', 4096);
        errdefer allocator.free(app_token);

        const trimmed_app = std.mem.trimRight(u8, app_token, "\r\n ");
        try validateAppToken(trimmed_app);

        // Validate with auth.test
        var client = api.SlackClient.init(allocator, trimmed_user, trimmed_app);
        defer client.deinit();

        const auth_resp = try client.authTest();

        return Auth{
            .user_token = trimmed_user,
            .app_token = trimmed_app,
            .team_id = try allocator.dupe(u8, auth_resp.team_id orelse return error.SlackApiError),
            .user_id = try allocator.dupe(u8, auth_resp.user_id orelse return error.SlackApiError),
        };
    }

    /// Validate user token format (pure function, testable).
    ///
    /// Preconditions:
    ///   - token is a non-empty string
    /// Postconditions:
    ///   - Returns void if token starts with "xoxp-" and has sufficient length
    ///   - Returns error.EmptyToken if token is empty
    ///   - Returns error.TokenTooShort if token is shorter than min_token_len
    ///   - Returns error.InvalidTokenFormat if prefix is wrong
    pub fn validateUserToken(token: []const u8) Error!void {
        if (token.len == 0) return error.EmptyToken;
        if (token.len < min_token_len) return error.TokenTooShort;
        if (!std.mem.startsWith(u8, token, user_token_prefix)) return error.InvalidTokenFormat;
    }

    /// Validate app token format (pure function, testable).
    ///
    /// Preconditions:
    ///   - token is a non-empty string
    /// Postconditions:
    ///   - Returns void if token starts with "xapp-" and has sufficient length
    ///   - Returns error.EmptyToken if token is empty
    ///   - Returns error.TokenTooShort if token is shorter than min_token_len
    ///   - Returns error.InvalidTokenFormat if prefix is wrong
    pub fn validateAppToken(token: []const u8) Error!void {
        if (token.len == 0) return error.EmptyToken;
        if (token.len < min_token_len) return error.TokenTooShort;
        if (!std.mem.startsWith(u8, token, app_token_prefix)) return error.InvalidTokenFormat;
    }

    /// Build Keychain service name for user token.
    /// Returns formatted service name or null if team_id is too long.
    pub fn userServiceName(buf: []u8, team_id: []const u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "zlack.user.{s}", .{team_id}) catch null;
    }

    /// Build Keychain service name for app token.
    /// Returns formatted service name or null if team_id is too long.
    pub fn appServiceName(buf: []u8, team_id: []const u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "zlack.app.{s}", .{team_id}) catch null;
    }
};

// =====================
// Tests (pure functions only -- no network, no Keychain)
// =====================

test "validateUserToken rejects invalid prefix" {
    try std.testing.expectError(error.InvalidTokenFormat, Auth.validateUserToken("xoxb-invalid-token"));
}

test "validateAppToken rejects invalid prefix" {
    try std.testing.expectError(error.InvalidTokenFormat, Auth.validateAppToken("xoxp-invalid-token"));
}

test "validateUserToken accepts valid prefix" {
    try Auth.validateUserToken("xoxp-valid-token");
}

test "validateAppToken accepts valid prefix" {
    try Auth.validateAppToken("xapp-valid-token");
}

test "validateUserToken rejects empty string" {
    try std.testing.expectError(error.EmptyToken, Auth.validateUserToken(""));
}

test "validateAppToken rejects empty string" {
    try std.testing.expectError(error.EmptyToken, Auth.validateAppToken(""));
}

test "validateUserToken rejects token too short" {
    try std.testing.expectError(error.TokenTooShort, Auth.validateUserToken("xoxp-ab"));
}

test "validateAppToken rejects token too short" {
    try std.testing.expectError(error.TokenTooShort, Auth.validateAppToken("xapp-ab"));
}

test "validateUserToken rejects xapp- prefix" {
    try std.testing.expectError(error.InvalidTokenFormat, Auth.validateUserToken("xapp-some-token-value"));
}

test "validateAppToken rejects xoxp- prefix" {
    try std.testing.expectError(error.InvalidTokenFormat, Auth.validateAppToken("xoxp-some-token-value"));
}

test "validateUserToken boundary - exactly min_token_len" {
    // min_token_len = 10, "xoxp-" (5) + "12345" (5) = 10
    try Auth.validateUserToken("xoxp-12345");
}

test "validateAppToken boundary - exactly min_token_len" {
    try Auth.validateAppToken("xapp-12345");
}

test "validateUserToken boundary - min_token_len minus 1" {
    // 9 chars: "xoxp-" (5) + "1234" (4) = 9
    try std.testing.expectError(error.TokenTooShort, Auth.validateUserToken("xoxp-1234"));
}

test "validateAppToken boundary - min_token_len minus 1" {
    try std.testing.expectError(error.TokenTooShort, Auth.validateAppToken("xapp-1234"));
}

test "userServiceName formats correctly" {
    var buf: [128]u8 = undefined;
    const name = Auth.userServiceName(&buf, "T12345");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("zlack.user.T12345", name.?);
}

test "appServiceName formats correctly" {
    var buf: [128]u8 = undefined;
    const name = Auth.appServiceName(&buf, "T12345");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("zlack.app.T12345", name.?);
}

test "userServiceName returns null for oversized team_id" {
    var buf: [10]u8 = undefined; // too small for "zlack.user." + team_id
    const name = Auth.userServiceName(&buf, "T12345678901234567890");
    try std.testing.expect(name == null);
}
