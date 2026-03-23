const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});

/// Convert Slack ts ("1773282759.367279") to "YYYY-MM-DD HH:MM:SS" in local timezone.
pub fn formatSlackTs(ts: []const u8, buf: *[20]u8) []const u8 {
    const dot_pos = std.mem.indexOfScalar(u8, ts, '.') orelse ts.len;
    const epoch = std.fmt.parseInt(i64, ts[0..dot_pos], 10) catch return ts;
    var time_val: c.time_t = @intCast(epoch);
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&time_val, &tm) == null) return ts;
    const result = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.tm_year + 1900)),
        @as(u32, @intCast(tm.tm_mon + 1)),
        @as(u32, @intCast(tm.tm_mday)),
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        @as(u32, @intCast(tm.tm_sec)),
    }) catch return ts;
    return result;
}

// ===========================================================================
// Tests
// ===========================================================================

test "formatSlackTs valid epoch" {
    var buf: [20]u8 = undefined;
    const result = formatSlackTs("0.000000", &buf);
    try std.testing.expect(result.len == 19);
    try std.testing.expect(result[4] == '-');
    try std.testing.expect(result[10] == ' ');
    try std.testing.expect(result[13] == ':');
}

test "formatSlackTs with decimal part" {
    var buf: [20]u8 = undefined;
    const result = formatSlackTs("1700000000.123456", &buf);
    try std.testing.expect(result.len == 19);
    try std.testing.expect(std.mem.startsWith(u8, result, "2023-11-1"));
}

test "formatSlackTs invalid returns original" {
    var buf: [20]u8 = undefined;
    const result = formatSlackTs("not_a_number", &buf);
    try std.testing.expectEqualStrings("not_a_number", result);
}

test "formatSlackTs empty string returns original" {
    var buf: [20]u8 = undefined;
    const result = formatSlackTs("", &buf);
    try std.testing.expectEqualStrings("", result);
}

test "formatSlackTs no dot" {
    var buf: [20]u8 = undefined;
    const result = formatSlackTs("1700000000", &buf);
    try std.testing.expect(result.len == 19);
}

test "formatSlackTs_XSS_injection" {
    var buf: [20]u8 = undefined;
    const result = formatSlackTs("<script>alert(1)</script>", &buf);
    try std.testing.expectEqualStrings("<script>alert(1)</script>", result);
}

test "formatSlackTs_PathTraversal" {
    var buf: [20]u8 = undefined;
    const result = formatSlackTs("../../etc/passwd", &buf);
    try std.testing.expectEqualStrings("../../etc/passwd", result);
}
