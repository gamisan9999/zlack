const std = @import("std");

/// Sanitize a filename from external source (Slack API).
/// Extracts basename only, removing directory traversal and path separators.
pub fn sanitizeFilename(name: []const u8) []const u8 {
    var basename = name;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |pos| {
        basename = name[pos + 1 ..];
    }
    if (std.mem.lastIndexOfScalar(u8, basename, '\\')) |pos| {
        basename = basename[pos + 1 ..];
    }
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) {
        return "download";
    }
    return basename;
}

// ===========================================================================
// Tests — Path Traversal (OWASP A01:2025)
// ===========================================================================

test "sanitizeFilename_normal" {
    try std.testing.expectEqualStrings("photo.png", sanitizeFilename("photo.png"));
}

test "sanitizeFilename_PathTraversal_dotdot" {
    try std.testing.expectEqualStrings("evil.txt", sanitizeFilename("../../evil.txt"));
}

test "sanitizeFilename_PathTraversal_absolute" {
    try std.testing.expectEqualStrings("passwd", sanitizeFilename("/etc/passwd"));
}

test "sanitizeFilename_PathTraversal_deep" {
    try std.testing.expectEqualStrings("key", sanitizeFilename("../../../../.ssh/key"));
}

test "sanitizeFilename_PathTraversal_backslash" {
    try std.testing.expectEqualStrings("file.exe", sanitizeFilename("..\\..\\file.exe"));
}

test "sanitizeFilename_PathTraversal_mixed" {
    try std.testing.expectEqualStrings("payload.sh", sanitizeFilename("../foo/../../bar\\payload.sh"));
}

test "sanitizeFilename_empty" {
    try std.testing.expectEqualStrings("download", sanitizeFilename(""));
}

test "sanitizeFilename_dot_only" {
    try std.testing.expectEqualStrings("download", sanitizeFilename("."));
}

test "sanitizeFilename_dotdot_only" {
    try std.testing.expectEqualStrings("download", sanitizeFilename(".."));
}

test "sanitizeFilename_trailing_slash" {
    // "/" after basename results in empty → fallback
    try std.testing.expectEqualStrings("download", sanitizeFilename("foo/"));
}

test "sanitizeFilename_japanese" {
    try std.testing.expectEqualStrings("report.pdf", sanitizeFilename("reports/report.pdf"));
}

test "sanitizeFilename_spaces" {
    try std.testing.expectEqualStrings("my file.txt", sanitizeFilename("my file.txt"));
}

test "sanitizeFilename_XSS_in_filename" {
    // The / in </script> is treated as a path separator → basename is "script>.html"
    // This is safe: the dangerous part is stripped by basename extraction
    try std.testing.expectEqualStrings("script>.html", sanitizeFilename("<script>alert(1)</script>.html"));
}
