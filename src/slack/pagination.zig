const std = @import("std");
const types = @import("types.zig");

/// Generic cursor-based pagination for Slack API.
///
/// Preconditions:
///   - `Response` must have a field `response_metadata: ?types.ResponseMetadata`
///   - `Response` must have a data field (e.g. `channels`, `members`) whose name is given by `data_field`
///   - `data_field` must name a field of type `?[]const Item`
///
/// Postconditions:
///   - Returns a slice containing all items concatenated from every page.
///   - Caller owns the returned slice and must free it with `allocator.free(result)`.
///   - If no items exist across all pages, returns an empty slice (len == 0).
pub fn fetchAllPages(
    comptime Response: type,
    comptime Item: type,
    comptime data_field: []const u8,
    allocator: std.mem.Allocator,
    context: anytype,
    callback: fn (@TypeOf(context), ?[]const u8) anyerror!Response,
) ![]const Item {
    var all_items: std.ArrayList(Item) = .empty;
    errdefer all_items.deinit(allocator);

    var cursor: ?[]const u8 = null;

    while (true) {
        const response = try callback(context, cursor);

        // Append items from this page
        if (@field(response, data_field)) |items| {
            try all_items.appendSlice(allocator, items);
        }

        // Check for next page
        if (response.response_metadata) |meta| {
            if (meta.next_cursor) |next| {
                if (next.len > 0) {
                    cursor = next;
                    continue;
                }
            }
        }
        break;
    }

    return all_items.toOwnedSlice(allocator);
}

// --- Tests ---

const TestResponse = struct {
    ok: bool,
    items: ?[]const TestItem = null,
    response_metadata: ?types.ResponseMetadata = null,
};

const TestItem = struct {
    id: []const u8,
};

const MockContext = struct {
    pages: []const TestResponse,
    call_count: *usize,

    fn fetch(self: MockContext, cursor: ?[]const u8) anyerror!TestResponse {
        const idx = self.call_count.*;
        self.call_count.* += 1;

        if (cursor != null and idx < self.pages.len) {
            return self.pages[idx];
        }
        if (cursor == null and idx == 0) {
            return self.pages[0];
        }
        // Should not reach here in well-formed tests
        return self.pages[self.pages.len - 1];
    }
};

test "empty response - returns 0 items, calls callback once" {
    var call_count: usize = 0;
    const pages = [_]TestResponse{
        .{
            .ok = true,
            .items = &[_]TestItem{},
            .response_metadata = .{ .next_cursor = "" },
        },
    };
    const ctx = MockContext{
        .pages = &pages,
        .call_count = &call_count,
    };

    const result = try fetchAllPages(
        TestResponse,
        TestItem,
        "items",
        std.testing.allocator,
        ctx,
        MockContext.fetch,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expect(result.len == 0);
    try std.testing.expect(call_count == 1);
}

test "single page - returns all items from that page" {
    var call_count: usize = 0;
    const item_a = TestItem{ .id = "a" };
    const item_b = TestItem{ .id = "b" };
    const items_slice = [_]TestItem{ item_a, item_b };
    const pages = [_]TestResponse{
        .{
            .ok = true,
            .items = &items_slice,
            .response_metadata = .{ .next_cursor = "" },
        },
    };
    const ctx = MockContext{
        .pages = &pages,
        .call_count = &call_count,
    };

    const result = try fetchAllPages(
        TestResponse,
        TestItem,
        "items",
        std.testing.allocator,
        ctx,
        MockContext.fetch,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expect(result.len == 2);
    try std.testing.expectEqualStrings("a", result[0].id);
    try std.testing.expectEqualStrings("b", result[1].id);
    try std.testing.expect(call_count == 1);
}

test "multiple pages - combines items from both pages" {
    var call_count: usize = 0;
    const page1_items = [_]TestItem{
        .{ .id = "x" },
        .{ .id = "y" },
    };
    const page2_items = [_]TestItem{
        .{ .id = "z" },
    };
    const pages = [_]TestResponse{
        .{
            .ok = true,
            .items = &page1_items,
            .response_metadata = .{ .next_cursor = "cursor_page2" },
        },
        .{
            .ok = true,
            .items = &page2_items,
            .response_metadata = .{ .next_cursor = "" },
        },
    };
    const ctx = MockContext{
        .pages = &pages,
        .call_count = &call_count,
    };

    const result = try fetchAllPages(
        TestResponse,
        TestItem,
        "items",
        std.testing.allocator,
        ctx,
        MockContext.fetch,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expect(result.len == 3);
    try std.testing.expectEqualStrings("x", result[0].id);
    try std.testing.expectEqualStrings("y", result[1].id);
    try std.testing.expectEqualStrings("z", result[2].id);
    try std.testing.expect(call_count == 2);
}

test "null response_metadata - stops after first page" {
    var call_count: usize = 0;
    const page_items = [_]TestItem{
        .{ .id = "solo" },
    };
    const pages = [_]TestResponse{
        .{
            .ok = true,
            .items = &page_items,
            .response_metadata = null,
        },
    };
    const ctx = MockContext{
        .pages = &pages,
        .call_count = &call_count,
    };

    const result = try fetchAllPages(
        TestResponse,
        TestItem,
        "items",
        std.testing.allocator,
        ctx,
        MockContext.fetch,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expect(result.len == 1);
    try std.testing.expectEqualStrings("solo", result[0].id);
    try std.testing.expect(call_count == 1);
}

test "null items field - returns empty" {
    var call_count: usize = 0;
    const pages = [_]TestResponse{
        .{
            .ok = true,
            .items = null,
            .response_metadata = .{ .next_cursor = "" },
        },
    };
    const ctx = MockContext{
        .pages = &pages,
        .call_count = &call_count,
    };

    const result = try fetchAllPages(
        TestResponse,
        TestItem,
        "items",
        std.testing.allocator,
        ctx,
        MockContext.fetch,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expect(result.len == 0);
    try std.testing.expect(call_count == 1);
}
