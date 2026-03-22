const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// macOS Keychain wrapper using Security.framework.
/// On non-macOS platforms, all operations return error/null (stub).
pub const Keychain = if (builtin.os.tag == .macos) MacKeychain else StubKeychain;

const StubKeychain = struct {
    pub fn save(_: []const u8, _: []const u8, _: []const u8) !void {
        return error.KeychainNotAvailable;
    }
    pub fn load(_: Allocator, _: []const u8, _: []const u8) !?[]const u8 {
        return null;
    }
    pub fn delete(_: []const u8, _: []const u8) !void {}
};

const MacKeychain = struct {
    const c = @cImport({
        @cInclude("Security/Security.h");
    });

    /// Save (or update) a password in the Keychain.
    pub fn save(service: []const u8, account: []const u8, password: []const u8) !void {
        const cf_service = cfStr(service) orelse return error.CFStringCreateFailed;
        defer c.CFRelease(cf_service);
        const cf_account = cfStr(account) orelse return error.CFStringCreateFailed;
        defer c.CFRelease(cf_account);
        const cf_password = cfData(password) orelse return error.CFDataCreateFailed;
        defer c.CFRelease(cf_password);

        var keys = [_]?*const anyopaque{
            @as(?*const anyopaque, c.kSecClass),
            @as(?*const anyopaque, c.kSecAttrService),
            @as(?*const anyopaque, c.kSecAttrAccount),
            @as(?*const anyopaque, c.kSecValueData),
        };
        var values = [_]?*const anyopaque{
            @as(?*const anyopaque, c.kSecClassGenericPassword),
            cf_service,
            cf_account,
            cf_password,
        };

        const dict = c.CFDictionaryCreate(
            null,
            &keys,
            &values,
            @intCast(keys.len),
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        ) orelse return error.CFDictionaryCreateFailed;
        defer c.CFRelease(dict);

        const status = c.SecItemAdd(dict, null);
        if (status == c.errSecSuccess) return;

        if (status == c.errSecDuplicateItem) {
            // Update existing item
            var search_keys = [_]?*const anyopaque{
                @as(?*const anyopaque, c.kSecClass),
                @as(?*const anyopaque, c.kSecAttrService),
                @as(?*const anyopaque, c.kSecAttrAccount),
            };
            var search_values = [_]?*const anyopaque{
                @as(?*const anyopaque, c.kSecClassGenericPassword),
                cf_service,
                cf_account,
            };
            const search_dict = c.CFDictionaryCreate(
                null,
                &search_keys,
                &search_values,
                @intCast(search_keys.len),
                &c.kCFTypeDictionaryKeyCallBacks,
                &c.kCFTypeDictionaryValueCallBacks,
            ) orelse return error.CFDictionaryCreateFailed;
            defer c.CFRelease(search_dict);

            var update_keys = [_]?*const anyopaque{
                @as(?*const anyopaque, c.kSecValueData),
            };
            var update_values = [_]?*const anyopaque{
                cf_password,
            };
            const update_dict = c.CFDictionaryCreate(
                null,
                &update_keys,
                &update_values,
                @intCast(update_keys.len),
                &c.kCFTypeDictionaryKeyCallBacks,
                &c.kCFTypeDictionaryValueCallBacks,
            ) orelse return error.CFDictionaryCreateFailed;
            defer c.CFRelease(update_dict);

            const update_status = c.SecItemUpdate(search_dict, update_dict);
            if (update_status != c.errSecSuccess) return error.KeychainUpdateFailed;
            return;
        }

        return error.KeychainSaveFailed;
    }

    /// Load a password from the Keychain.
    /// Returns an owned slice that the caller must free, or null if not found.
    pub fn load(allocator: Allocator, service: []const u8, account: []const u8) !?[]const u8 {
        const cf_service = cfStr(service) orelse return error.CFStringCreateFailed;
        defer c.CFRelease(cf_service);
        const cf_account = cfStr(account) orelse return error.CFStringCreateFailed;
        defer c.CFRelease(cf_account);

        var keys = [_]?*const anyopaque{
            @as(?*const anyopaque, c.kSecClass),
            @as(?*const anyopaque, c.kSecAttrService),
            @as(?*const anyopaque, c.kSecAttrAccount),
            @as(?*const anyopaque, c.kSecReturnData),
        };
        var values = [_]?*const anyopaque{
            @as(?*const anyopaque, c.kSecClassGenericPassword),
            cf_service,
            cf_account,
            @as(?*const anyopaque, c.kCFBooleanTrue),
        };

        const dict = c.CFDictionaryCreate(
            null,
            &keys,
            &values,
            @intCast(keys.len),
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        ) orelse return error.CFDictionaryCreateFailed;
        defer c.CFRelease(dict);

        var result: c.CFTypeRef = null;
        const status = c.SecItemCopyMatching(dict, &result);

        if (status == c.errSecItemNotFound) return null;
        if (status != c.errSecSuccess) return error.KeychainLoadFailed;

        const cf_data: c.CFDataRef = @ptrCast(result);
        defer c.CFRelease(cf_data);

        const len: usize = @intCast(c.CFDataGetLength(cf_data));
        const ptr = c.CFDataGetBytePtr(cf_data);
        if (ptr == null) return error.KeychainLoadFailed;

        const buf = try allocator.alloc(u8, len);
        @memcpy(buf, ptr[0..len]);
        return buf;
    }

    /// Delete a password from the Keychain.
    /// Silently succeeds if the item does not exist.
    pub fn delete(service: []const u8, account: []const u8) !void {
        const cf_service = cfStr(service) orelse return error.CFStringCreateFailed;
        defer c.CFRelease(cf_service);
        const cf_account = cfStr(account) orelse return error.CFStringCreateFailed;
        defer c.CFRelease(cf_account);

        var keys = [_]?*const anyopaque{
            @as(?*const anyopaque, c.kSecClass),
            @as(?*const anyopaque, c.kSecAttrService),
            @as(?*const anyopaque, c.kSecAttrAccount),
        };
        var values = [_]?*const anyopaque{
            @as(?*const anyopaque, c.kSecClassGenericPassword),
            cf_service,
            cf_account,
        };

        const dict = c.CFDictionaryCreate(
            null,
            &keys,
            &values,
            @intCast(keys.len),
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        ) orelse return error.CFDictionaryCreateFailed;
        defer c.CFRelease(dict);

        const status = c.SecItemDelete(dict);
        if (status == c.errSecSuccess or status == c.errSecItemNotFound) return;
        return error.KeychainDeleteFailed;
    }

    fn cfStr(s: []const u8) ?*const anyopaque {
        const ref = c.CFStringCreateWithBytes(
            null,
            s.ptr,
            @intCast(s.len),
            c.kCFStringEncodingUTF8,
            0,
        ) orelse return null;
        return @ptrCast(ref);
    }

    fn cfData(s: []const u8) ?*const anyopaque {
        const ref = c.CFDataCreate(
            null,
            s.ptr,
            @intCast(s.len),
        ) orelse return null;
        return @ptrCast(ref);
    }
};

// ---------------------------------------------------------------------------
// Tests -- run against the real macOS Keychain (macOS only)
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_service = "zlack.test.keychain";
const test_account = "zlack.test.account";

test "save then load returns correct value" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    Keychain.delete(test_service, test_account) catch {};

    try Keychain.save(test_service, test_account, "secret123");
    defer Keychain.delete(test_service, test_account) catch {};

    const result = try Keychain.load(testing.allocator, test_service, test_account);
    try testing.expect(result != null);
    defer testing.allocator.free(result.?);
    try testing.expectEqualStrings("secret123", result.?);
}

test "load non-existent key returns null" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    Keychain.delete("zlack.test.nonexistent", "zlack.test.nouser") catch {};

    const result = try Keychain.load(testing.allocator, "zlack.test.nonexistent", "zlack.test.nouser");
    try testing.expect(result == null);
}

test "save then delete then load returns null" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    Keychain.delete(test_service, test_account) catch {};

    try Keychain.save(test_service, test_account, "to_be_deleted");
    try Keychain.delete(test_service, test_account);

    const result = try Keychain.load(testing.allocator, test_service, test_account);
    try testing.expect(result == null);
}

test "save twice (update) then load returns new value" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    Keychain.delete(test_service, test_account) catch {};

    try Keychain.save(test_service, test_account, "old_value");
    defer Keychain.delete(test_service, test_account) catch {};

    try Keychain.save(test_service, test_account, "new_value");

    const result = try Keychain.load(testing.allocator, test_service, test_account);
    try testing.expect(result != null);
    defer testing.allocator.free(result.?);
    try testing.expectEqualStrings("new_value", result.?);
}

test "stub keychain load returns null" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    const result = try Keychain.load(testing.allocator, "svc", "acct");
    try testing.expect(result == null);
}
